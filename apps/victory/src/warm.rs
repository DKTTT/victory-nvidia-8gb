//! `victory warm`: host pipelines made ahead of a run (`known_pipelines`), in
//! processes of their own: a compiler that crashes or hangs costs one pipeline.

use std::collections::HashSet;
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::time::{Duration, Instant};

use anyhow::{Context, Result};
use victory_hle::known_pipelines as known;

/// Pipelines a process makes before another takes its place: the compiler's
/// and the translations' memory goes with it. `VICTORY_WARM_BATCH` asks for
/// another (1 to 2,000): fewer process starts, more memory.
const AT_ONCE: usize = 40;

/// How many pipelines one process makes before it is replaced.
fn at_once() -> usize {
    static BATCH: std::sync::OnceLock<usize> = std::sync::OnceLock::new();
    *BATCH.get_or_init(|| {
        std::env::var("VICTORY_WARM_BATCH")
            .ok()
            .and_then(|v| v.trim().parse::<usize>().ok())
            .map_or(AT_ONCE, |n| n.clamp(1, 2000))
    })
}

/// The priority a warming process runs at: `idle` (the default, keeps the
/// desktop smooth) unless `VICTORY_WARM_PRIORITY` says `normal`, `above` or
/// `high` (the "fire at will" mode).
fn child_priority() -> u32 {
    static PRIORITY: std::sync::OnceLock<u32> = std::sync::OnceLock::new();
    *PRIORITY.get_or_init(|| match std::env::var("VICTORY_WARM_PRIORITY").map(|v| v.trim().to_lowercase()).as_deref() {
        Ok("normal") => 0x20,      // NORMAL_PRIORITY_CLASS
        Ok("above") => 0x8000,     // ABOVE_NORMAL_PRIORITY_CLASS
        Ok("high") => 0x80,        // HIGH_PRIORITY_CLASS
        _ => 0x40,                 // IDLE_PRIORITY_CLASS
    })
}
/// A pipeline that takes longer is taken for one the compiler hangs on.
const LONGEST: Duration = Duration::from_secs(180);

/// As the runs count one that takes long.
const SLOW_MS: f64 = 1000.0;

fn folder() -> Result<PathBuf> {
    let cfg = victory_core::Config::load()?;
    Ok(cfg.cache_subdir("shaders")?.with_file_name("pipelines"))
}

pub fn run(jobs: Option<usize>, limit: Option<usize>, again: bool, used: bool, these: Option<String>) -> Result<()> {
    let dir = folder()?;
    if let Some(these) = these {
        return make(&dir, &these);
    }
    let began = Instant::now();
    // (A first preload on a PC no run has written pipelines down on yet: none known.)
    std::fs::create_dir_all(&dir).with_context(|| format!("creating {}", dir.display()))?;
    victory_hle::known_pipelines::use_translations(dir.with_file_name("shaders"));
    // The driver keeps what is made here by program path: made by another copy of
    // this program, a pipeline is not made for this one.
    let fingerprint = {
        let program = std::env::current_exe().map(|p| p.to_string_lossy().to_lowercase()).unwrap_or_default();
        let mut h = blake3::Hasher::new();
        h.update(known::fingerprint().as_bytes());
        h.update(program.as_bytes());
        h.finalize().to_hex()[..16].to_owned()
    };
    let done_file = dir.join("warm-done.txt");
    let bad_file = dir.join("warm-bad.txt");
    let keys = known::keys(&dir);
    let listed = std::fs::read_to_string(&done_file).unwrap_or_default();
    let mut done: HashSet<&str> = HashSet::new();
    for line in listed.lines() {
        if let Some((of, key)) = line.split_once(' ')
            && of == fingerprint
        {
            done.insert(key);
        }
    }
    let bad = std::fs::read_to_string(&bad_file).unwrap_or_default();
    let bad: HashSet<&str> = bad.lines().filter_map(|l| l.split(' ').next()).collect();
    let early = std::fs::read_to_string(dir.join("early-pipelines.txt")).unwrap_or_default();
    let early: HashSet<&str> = early.lines().collect();
    // Those earlier runs drew with first, the others in no order (by key).
    let mut all: Vec<usize> = (0..keys.len())
        .filter(|&n| {
            let key = keys[n].as_str();
            (again || !done.contains(key)) && !bad.contains(key) && (!used || early.contains(key))
        })
        .collect();
    all.sort_by_key(|&n| (!early.contains(keys[n].as_str()), &keys[n]));
    all.truncate(limit.unwrap_or(usize::MAX));
    let cores = std::thread::available_parallelism().map_or(4, |n| n.get());
    let jobs = jobs.unwrap_or(cores * 2 / 3).max(1);
    println!(
        "{} pipelines known, {} made before ({fingerprint}), {} bad; {} to make, {jobs} processes",
        keys.len(),
        done.len(),
        bad.len(),
        all.len()
    );
    let chunks: Vec<&[usize]> = all.chunks(at_once()).collect();
    let next = AtomicUsize::new(0);
    let progress = Mutex::new(Instant::now());
    let state = Mutex::new((Vec::<f64>::new(), 0usize, 0usize));
    let done_out = Mutex::new(std::fs::OpenOptions::new().create(true).append(true).open(&done_file)?);
    // (Read back by the runs: these are made beside the others, not before.)
    let slow_out = Mutex::new(std::fs::OpenOptions::new().create(true).append(true).open(dir.join("slow-pipelines.txt"))?);
    let bad_out = Mutex::new(std::fs::OpenOptions::new().create(true).append(true).open(&bad_file)?);
    std::thread::scope(|s| {
        for _ in 0..jobs.min(chunks.len()) {
            s.spawn(|| {
                while let Some(&chunk) = chunks.get(next.fetch_add(1, Ordering::Relaxed)) {
                    let mut rest = chunk;
                    while !rest.is_empty() {
                        let (made, ended) = child(rest, |n, ms, there| {
                            if ms >= SLOW_MS {
                                let _ = writeln!(lock(&slow_out), "\n{} {ms:.0}", keys[n]);
                            }
                            let mut state = lock(&state);
                            state.0.push(ms);
                            state.1 += usize::from(!there);
                            let count = state.0.len();
                            let mut prog = lock(&progress);
                            if count.is_multiple_of(100) || prog.elapsed() >= Duration::from_secs(2) {
                                *prog = Instant::now();
                                let elapsed = began.elapsed().as_secs_f64();
                                let rate = count as f64 / elapsed.max(0.001);
                                let left = all.len().saturating_sub(count) as f64 / rate.max(0.1);
                                println!(
                                    "[progress] {count}/{} ({:.1}%) | {} | {rate:.1}/s | ETA {}",
                                    all.len(),
                                    count as f64 * 100.0 / all.len().max(1) as f64,
                                    mmss(elapsed),
                                    mmss(left)
                                );
                            }
                            drop(state);
                            let _ = writeln!(lock(&done_out), "{fingerprint} {}", keys[n]);
                        });
                        rest = &rest[made.min(rest.len())..];
                        match (ended, rest.split_first()) {
                            (Some(why), Some((&n, after))) => {
                                // The one it was at.
                                println!("pipeline {n} {}: {why}", keys[n]);
                                let _ = writeln!(lock(&bad_out), "{} {why}", keys[n]);
                                lock(&state).2 += 1;
                                rest = after;
                            }
                            _ => break,
                        }
                    }
                }
            });
        }
    });
    let (mut times, refused, crashed) = state.into_inner().unwrap_or_else(|e| e.into_inner());
    let spent = began.elapsed().as_secs_f64();
    times.sort_by(f64::total_cmp);
    let at = |q: f64| times.get((times.len() as f64 * q) as usize).copied().unwrap_or(0.0);
    println!(
        "[done] {} made in {:.0} s (average {:.1}/s; {refused} have no host pipeline, {crashed} ended their process); ms each: median {:.1}, p90 {:.1}, p99 {:.1}, most {:.0}, sum {:.0} s",
        times.len(),
        spent,
        times.len() as f64 / spent.max(0.001),
        at(0.5),
        at(0.9),
        at(0.99),
        times.last().copied().unwrap_or(0.0),
        times.iter().sum::<f64>() / 1e3
    );
    Ok(())
}

/// `victory preload`'s last step: the pipelines a run makes while it loads
/// (the early list) and those that take a second or more, made again in this
/// process and stored in the host pipeline library the runs load at their
/// start. `run` made them in processes of their own first, so the driver has
/// them and they come quickly; those that ended a process are left out. Not
/// all the known ones: one process holding the compiler's memory for 88,000
/// pipelines is what `AT_ONCE` keeps `run` from.
pub fn into_library(jobs: Option<usize>) -> Result<()> {
    let dir = folder()?;
    let cfg = victory_core::Config::load()?;
    known::use_library(cfg.cache_subdir("shaders")?);
    let keys = known::keys(&dir);
    let read = |file: &str| std::fs::read_to_string(dir.join(file)).unwrap_or_default();
    let (bad, early, slow) = (read("warm-bad.txt"), read("early-pipelines.txt"), read("slow-pipelines.txt"));
    let bad: HashSet<&str> = bad.lines().filter_map(|l| l.split(' ').next()).collect();
    let early: HashSet<&str> = early.lines().collect();
    let slow: HashSet<&str> = slow.lines().filter_map(|l| l.split(' ').next()).filter(|k| !k.is_empty()).collect();
    let mut all: Vec<usize> = (0..keys.len())
        .filter(|&n| {
            let key = keys[n].as_str();
            !bad.contains(key) && (early.contains(key) || slow.contains(key))
        })
        .collect();
    all.sort_by_key(|&n| (!early.contains(keys[n].as_str()), &keys[n]));
    let threads = jobs.unwrap_or_else(|| std::thread::available_parallelism().map_or(4, |n| n.get()) * 2 / 3).max(1);
    println!("into the pipeline library: {} pipelines (loading and slow ones), {threads} threads", all.len());
    let began = Instant::now();
    let (count, made) = (AtomicUsize::new(0), AtomicUsize::new(0));
    let progress = Mutex::new(Instant::now());
    std::thread::scope(|s| {
        for t in 0..threads {
            let these: Vec<usize> = all.iter().copied().skip(t).step_by(threads).collect();
            let (count, made, total, dir) = (&count, &made, all.len(), &dir);
            let progress = &progress;
            s.spawn(move || {
                known::make(dir, &these, |_, came| {
                    let Some((_, there)) = came else { return };
                    made.fetch_add(usize::from(there), Ordering::Relaxed);
                    let n = count.fetch_add(1, Ordering::Relaxed) + 1;
                    let mut prog = lock(&progress);
                    if n.is_multiple_of(100) || prog.elapsed() >= Duration::from_secs(2) {
                        *prog = Instant::now();
                        let elapsed = began.elapsed().as_secs_f64();
                        let rate = n as f64 / elapsed.max(0.001);
                        let left = total.saturating_sub(n) as f64 / rate.max(0.1);
                        println!("[library] {n}/{total} in the pipeline library | {} | {rate:.1}/s | ETA {}", mmss(elapsed), mmss(left));
                    }
                });
            });
        }
    });
    known::keep_library();
    println!(
        "{} of {} in the pipeline library in {:.0} s",
        made.load(Ordering::Relaxed),
        all.len(),
        began.elapsed().as_secs_f64()
    );
    Ok(())
}

fn lock<T>(m: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

/// Seconds as `12m34s`, for the progress lines.
fn mmss(seconds: f64) -> String {
    let s = seconds.max(0.0) as u64;
    format!("{}m{:02}s", s / 60, s % 60)
}

/// Has a process make `these`; how many it made, and how it ended if not well.
fn child(these: &[usize], mut each: impl FnMut(usize, f64, bool)) -> (usize, Option<String>) {
    let list: Vec<String> = these.iter().map(usize::to_string).collect();
    let spawned = std::env::current_exe().and_then(|exe| {
        use std::os::windows::process::CommandExt;
        const IDLE_PRIORITY_CLASS: u32 = 0x40;
        Command::new(exe)
            .args(["warm", "--these", &list.join(",")])
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .creation_flags(IDLE_PRIORITY_CLASS)
            .spawn()
    });
    let Ok(mut process) = spawned else { return (these.len(), None) };
    let Some(out) = process.stdout.take() else { return (these.len(), None) };
    let process = Mutex::new(process);
    let (heard, over) = (Mutex::new(Instant::now()), AtomicBool::new(false));
    let hung = AtomicBool::new(false);
    let mut made = 0;
    std::thread::scope(|s| {
        s.spawn(|| {
            while !over.load(Ordering::Relaxed) {
                std::thread::sleep(Duration::from_millis(500));
                if lock(&heard).elapsed() > LONGEST {
                    hung.store(true, Ordering::Relaxed);
                    let _ = lock(&process).kill();
                    return;
                }
            }
        });
        for line in BufReader::new(out).lines().map_while(Result::ok) {
            *lock(&heard) = Instant::now();
            let mut words = line.split(' ');
            if words.next() == Some("made")
                && let (Some(n), Some(ms), Some(there)) = (words.next(), words.next(), words.next())
                && let (Ok(n), Ok(ms)) = (n.parse(), ms.parse())
            {
                made += 1;
                each(n, ms, there == "1");
            }
        }
        over.store(true, Ordering::Relaxed);
    });
    let status = lock(&process).wait();
    let well = status.as_ref().is_ok_and(|s| s.success());
    if well {
        return (these.len(), None);
    }
    let why = if hung.load(Ordering::Relaxed) {
        format!("hung for {} s", LONGEST.as_secs())
    } else {
        status.map_or_else(|e| e.to_string(), |s| format!("{s}"))
    };
    (made, Some(why))
}

/// What such a process does.
fn make(dir: &Path, these: &str) -> Result<()> {
    let these: Vec<usize> = these.split(',').map(|n| n.parse().context("--these")).collect::<Result<_>>()?;
    let cfg = victory_core::Config::load()?;
    victory_hle::known_pipelines::use_translations(cfg.cache_subdir("shaders")?);
    let mut out = std::io::stdout();
    known::make(dir, &these, |n, came| {
        let told = match came {
            None => writeln!(out, "at {n}"),
            Some((ms, there)) => writeln!(out, "made {n} {ms:.2} {}", u8::from(there)),
        };
        if told.and_then(|()| out.flush()).is_err() {
            // Whoever asked is gone.
            std::process::exit(1);
        }
    });
    // Without what a run's end does (nothing to save, the host's threads).
    let _ = out.flush();
    std::process::exit(0)
}
