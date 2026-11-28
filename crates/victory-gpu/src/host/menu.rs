//! The F1 settings menu. F1 shows and hides it while our window has the
//! focus; Up/Down pick a setting, Left/Right change it, Enter runs the line
//! picked (save, save and restart, preload shaders, reset, close), Esc
//! closes. Preloading saves, ends this run and has the launcher make every
//! shader before the title starts again (`VICTORY_PRELOAD=1`, `victory
//! preload`); it asks for a second Enter first. While it is
//! shown the title sees no keyboard (`crate::SETTINGS_MENU_OPEN`, read by the
//! input module); a pad still works.
//!
//! The settings are read once at start, so a change is saved to the file
//! `VICTORY_MENU_FILE` names (`scripts\play-foxhound.ps1` sets it to
//! `victory-settings.txt` in the repository's folder and applies it at every
//! start) and takes effect at the next start; "SAVE AND RESTART" starts the
//! launcher again (`VICTORY_MENU_PLAY`, with `VICTORY_MENU_ARGS`) and ends
//! this run. The `VICTORY_MENU_...` settings are the launcher's own choices
//! (DLSS mode, frame generation, frame rate, console, picture size), which it
//! turns into the layer's switches; the others are the switches themselves.
//!
//! In every build, as the stats panel is. Drawn as
//! that panel is: white text on a black box, copied onto the swap chain's
//! buffer, in the middle of the picture.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Mutex, OnceLock};
use std::time::Duration;

use windows::Win32::Graphics::Direct3D12::*;
use windows::Win32::Graphics::Dxgi::Common::*;
use windows_sys::Win32::UI::Input::KeyboardAndMouse::{
    GetAsyncKeyState, VK_DOWN, VK_ESCAPE, VK_F1, VK_LEFT, VK_RETURN, VK_RIGHT, VK_UP,
};
use windows_sys::Win32::UI::WindowsAndMessaging::{GetForegroundWindow, GetWindowThreadProcessId};

use super::font::colours;
use super::font_cn::{advance, glyph_rows, text_width, LINE_H};
use super::{Host, HostList, transition};

/// 菜单框基准宽度（像素），绘制时乘 scale。
const BOX_W: u32 = 640;
/// Lines of the box: a title, a help line, a blank, the settings shown, a
/// blank, what the line picked does (`ABOUT`, else blank), a note and the
/// repository's link.
const ROWS: usize = 20;
const LINES: u32 = ROWS as u32 + 9;
/// The action that preloads shaders, and what is said of it while it is picked.
const PRELOAD: usize = 2;
const ABOUT_PRELOAD: [&str; 3] = [
    "预载会先编译全部着色器，再重启游戏。",
    "需要一些时间，长短看硬件（主要看 CPU）。",
    "以后更新构建或显卡驱动，可能需要重新预载。",
];
/// The note after the first Enter on it: the second one does it.
const CONFIRM_PRELOAD: &str = "再按一次回车：保存、关闭游戏并预载着色器";
/// The last line of the box: where this build comes from.
const REPO: &str = "GITHUB.COM/TRUSTNO1-CODER/VICTORY-NVIDIA";
const RIM: u32 = 4;
const GLYPH_H: u32 = 16;
const UPLOADS: usize = 4;

/// A setting: the variable, its name in the menu, the values it takes
/// (`""`: not set, the build's own default), and whether a change applies at once.
struct Item {
    var: &'static str,
    label: &'static str,
    values: &'static [(&'static str, &'static str)],
    live: bool,
}

/// 中文菜单的静态文案。
const TITLE: &str = "设置";
const TITLE_RIGHT: &str = "F1 或 ESC 关闭";
const HELP: &str = "上下选择  左右修改  回车执行";
const NOTE: &str = "* = 已修改：下次启动生效（即时=立即生效）";
const MARKS: [&str; 2] = [" 即时", " *"];

/// 右侧补空格到指定像素宽。
fn pad_to(s: &str, px: u32) -> String {
    if px <= text_width(s) {
        return s.to_owned();
    }
    let mut out = String::from(s);
    let mut left = px - text_width(s);
    while left >= 8 {
        out.push(' ');
        left -= 8;
    }
    out
}

fn pad_label(s: &str) -> String {
    pad_to(s, 200)
}

const ON_UNSET: &[(&str, &str)] = &[("1", "开"), ("", "关")];
const UNSET_ON: &[(&str, &str)] = &[("", "关"), ("1", "开")];
const STAGES: &[(&str, &str)] = &[("2", "2"), ("1", "1"), ("0", "0关")];

/// The first value of each is what the launcher starts with.
#[rustfmt::skip]
const ITEMS: &[Item] = &[
    // The launcher's own choices.
    Item { var: "VICTORY_MENU_DLSS", label: "DLSS", values: &[("quality", "画质"), ("balanced", "均衡"), ("performance", "性能"), ("dlaa", "DLAA(原生)"), ("off", "关")], live: false },
    Item { var: "VICTORY_MENU_FRAMEGEN", label: "帧生成", values: &[("0", "关"), ("2", "2X"), ("3", "3X"), ("4", "4X"), ("5", "5X"), ("6", "6X(最大)")], live: false },
    // DLSS 帧生成能跑就用 DLSS（RTX 40 起），否则用 AMD FSR 3（只有 2X）。
    Item { var: "VICTORY_MENU_FG_TYPE", label: "帧生成类型(重启)", values: &[("auto", "自动"), ("dlss", "DLSS"), ("fsr", "FSR 3(老卡)")], live: false },
    Item { var: "VICTORY_MENU_FPS", label: "帧率上限", values: &[("1000", "无"), ("120", "120"), ("60", "60"), ("30", "30(游戏)")], live: false },
    Item { var: "VICTORY_FPS_LINE", label: "顶部帧率", values: &[("1", "开"), ("0", "关")], live: true },
    Item { var: "VICTORY_PANEL", label: "状态面板(F3)", values: &[("0", "关"), ("1", "开")], live: true },
    Item { var: "VICTORY_FULLSCREEN", label: "全屏(无边框)", values: UNSET_ON, live: false },
    Item { var: "VICTORY_MOUSE_CAPTURE", label: "鼠标捕获", values: UNSET_ON, live: false },
    Item { var: "VICTORY_IME_ENGLISH", label: "英文键盘", values: UNSET_ON, live: false },
    Item { var: "VICTORY_MENU_CONSOLE", label: "主机模式", values: &[("series-x", "系列X"), ("series-s", "系列S(更快)")], live: false },
    Item { var: "VICTORY_MENU_RES", label: "画面尺寸", values: &[("1440", "2560x1440"), ("1080to1440", "1080p拉伸"), ("4k", "3840x2160")], live: false },
    // The layer's switches.
    Item { var: "VICTORY_DLSS_PRESET", label: "DLSS 模型", values: &[("", "默认"), ("k", "K"), ("j", "J"), ("m", "M"), ("l", "L")], live: false },
    Item { var: "VICTORY_AMBIENT", label: "光照估算", values: &[("0.8", "0.8"), ("1", "1"), ("0.5", "0.5"), ("", "关")], live: false },
    Item { var: "VICTORY_AMBIENT_RT", label: "环境光(RT)", values: &[("", "关"), ("1,1.5,0.8", "开"), ("0.5,3,1", "强")], live: false },
    Item { var: "VICTORY_AMBIENT_SPECULAR", label: "反射估算", values: ON_UNSET, live: false },
    Item { var: "VICTORY_AMBIENT_AIR", label: "雾上限", values: &[("1.5", "1.5"), ("1", "1"), ("2", "2"), ("", "无")], live: false },
    Item { var: "VICTORY_BVH_BUILDER", label: "光线追踪(慢/坏)", values: UNSET_ON, live: false },
    Item { var: "VICTORY_WATER_LIGHT", label: "水面光照", values: &[("", "关(无黑块)"), ("1", "开(绿,黑块)")], live: false },
    Item { var: "VICTORY_LEAVE_OUT", label: "热浪与贴花整理", values: &[("02384a60fda6f2d0,731a39171b568298", "跳过"), ("", "运行(更慢)")], live: false },
    Item { var: "VICTORY_EARLY_DEPTH", label: "早期深度测试", values: ON_UNSET, live: false },
    Item { var: "VICTORY_WC_NO_BACK", label: "跳过大量回读", values: ON_UNSET, live: false },
    Item { var: "VICTORY_SOFT_VIEWS", label: "软视图(防卡顿)", values: &[("copies", "开"), ("", "关")], live: false },
    Item { var: "VICTORY_TEXTURE_NO_WAIT", label: "纹理不等待", values: ON_UNSET, live: false },
    Item { var: "VICTORY_RELAY", label: "RELAY(速度/三角)", values: STAGES, live: false },
    Item { var: "VICTORY_CARD_STEPS", label: "卡片步进", values: STAGES, live: false },
    Item { var: "VICTORY_INDIRECT_BATCH", label: "间接批次", values: STAGES, live: false },
    Item { var: "VICTORY_CARD_BUFFERS_MIN_KB", label: "比较起点(KB)", values: &[("64", "64"), ("1024", "1024")], live: false },
    Item { var: "VICTORY_PORT_CONSTANTS", label: "常量堆原地", values: UNSET_ON, live: false },
];
/// The lines after the settings.
const ACTIONS: [&str; 5] = ["立即保存并重启", "保存(下次启动)", "预载着色器(重启游戏)", "全部恢复默认", "关闭"];

fn get(var: &str) -> String {
    std::env::var(var).unwrap_or_default()
}

/// Starts `command_line` in a console window of its own, with that console's input and output.
/// (`std::process::Command` always hands its child this process's standard handles: the restarted
/// launcher then wrote into the old launcher's pipe and log, not its own window, and kept the old
/// launcher waiting on that pipe.)
fn new_console(command_line: &str) -> std::io::Result<()> {
    use windows_sys::Win32::Foundation::CloseHandle;
    use windows_sys::Win32::System::Threading::{CREATE_NEW_CONSOLE, CreateProcessW, PROCESS_INFORMATION, STARTUPINFOW};
    let mut line: Vec<u16> = command_line.encode_utf16().chain(Some(0)).collect();
    // SAFETY: plain structs, zero is their empty value.
    let mut startup: STARTUPINFOW = unsafe { std::mem::zeroed() };
    startup.cb = std::mem::size_of::<STARTUPINFOW>() as u32;
    let mut process: PROCESS_INFORMATION = unsafe { std::mem::zeroed() };
    // SAFETY: `line` is a writable, terminated UTF-16 string; no handles inherited; this
    // process's environment and folder.
    let made = unsafe {
        CreateProcessW(
            std::ptr::null(),
            line.as_mut_ptr(),
            std::ptr::null(),
            std::ptr::null(),
            0,
            CREATE_NEW_CONSOLE,
            std::ptr::null(),
            std::ptr::null(),
            &startup,
            &mut process,
        )
    };
    if made == 0 {
        return Err(std::io::Error::last_os_error());
    }
    // SAFETY: the two handles CreateProcessW gave, closed once.
    unsafe {
        CloseHandle(process.hThread);
        CloseHandle(process.hProcess);
    }
    Ok(())
}

/// Whether a change of `item` shows at once. Frame generation does when this run started with
/// it ready (the launcher asks for that whenever Streamline is there).
fn live(item: &Item) -> bool {
    item.live || (item.var == "VICTORY_MENU_FRAMEGEN" && crate::streamline::framegen_live())
}

/// Whether the frame-rate line is shown at the top while the menu is closed
/// (`VICTORY_FPS_LINE=0`: not; the menu changes it).
fn fps_line_on() -> &'static AtomicBool {
    static ON: OnceLock<AtomicBool> = OnceLock::new();
    ON.get_or_init(|| AtomicBool::new(std::env::var_os("VICTORY_FPS_LINE").is_none_or(|v| v != "0")))
}

/// That line: the frames rendered a second and, while frame generation shows more, those shown.
fn fps_line() -> Option<String> {
    if !fps_line_on().load(Ordering::Relaxed) {
        return None;
    }
    // The stats panel has that corner (F3), and says the same.
    if super::panel::shown().load(Ordering::Relaxed) {
        return None;
    }
    // (Victory) the same figures as the F10 panel, in its style
    let stats = crate::overlay::snapshot()?;
    let fps = stats.fps;
    if fps <= 0.0 {
        return None;
    }
    let per = crate::streamline::shown_per_frame().max(1);
    let shown = fps * f64::from(per);
    let mut out = if per == 1 {
        format!("FPS {fps:.1}   {:.1} ms", stats.ms)
    } else {
        format!("FPS {fps:.1} x{per}   {shown:.1} shown   {:.1} ms", stats.ms)
    };
    if let Some((low, high, avg)) = stats.half_minute {
        out.push_str(&format!("   30s avg {avg:.1}  high {high:.1}  low {low:.1}"));
    }
    out.push_str(&format!("   draws {:.0}", stats.draws));
    if let Some(gpu) = stats.gpu {
        out.push_str(&format!("   GPU {gpu:.0}%"));
    }
    if let Some((used, budget)) = stats.vram {
        out.push_str(&format!("   VRAM {used:.1}/{budget:.1} GB"));
    }
    Some(out)
}

/// The index of `value` among the item's values (an unknown value: shown as
/// itself, at the end).
fn index_of(item: &Item, value: &str) -> Option<usize> {
    item.values.iter().position(|(v, _)| *v == value)
}

/// What the menu shows for `value`: its label, an unknown value as itself,
/// and a value the launcher did not set (a start without play.ps1) as
/// "NOT SET" rather than a blank.
fn shown_value(item: &Item, value: &str) -> String {
    match index_of(item, value) {
        Some(i) => item.values[i].1.to_owned(),
        None if value.is_empty() => "未设置".to_owned(),
        None => value.to_ascii_uppercase(),
    }
}

/// Keys pressed, gathered on a thread of their own every 10 ms: a frame
/// lasts 50 ms and more, and a short press would fall between two frames.
fn keys() -> &'static Mutex<Vec<u16>> {
    static KEYS: OnceLock<Mutex<Vec<u16>>> = OnceLock::new();
    KEYS.get_or_init(|| {
        let _ = std::thread::Builder::new().name("settings menu keys".into()).spawn(|| {
            const WATCHED: [u16; 7] = [VK_F1, VK_UP, VK_DOWN, VK_LEFT, VK_RIGHT, VK_RETURN, VK_ESCAPE];
            let mut was = [false; WATCHED.len()];
            loop {
                std::thread::sleep(Duration::from_millis(10));
                let mut process = 0;
                // SAFETY: plain queries; room for the answer.
                unsafe { GetWindowThreadProcessId(GetForegroundWindow(), &mut process) };
                let ours = process == std::process::id();
                for (i, &vk) in WATCHED.iter().enumerate() {
                    // SAFETY: a plain query.
                    let down = ours && unsafe { GetAsyncKeyState(i32::from(vk)) } < 0;
                    if down && !was[i] {
                        keys().lock().unwrap_or_else(|e| e.into_inner()).push(vk);
                    }
                    was[i] = down;
                }
            }
        });
        Mutex::new(Vec::new())
    })
}

/// 菜单框尺寸（像素）。
#[allow(dead_code)]
const fn size(scale: u32) -> (u32, u32) {
    ((BOX_W + 2 * RIM) * scale, (LINES * LINE_H + 2 * RIM) * scale)
}

/// 把一行文字画进掩码（基准分辨率）。
fn paint_line(mask: &mut [bool], mask_w: u32, mask_h: u32, line: &str, x0: u32, y0: u32) {
    let mut x = x0;
    for ch in line.chars() {
        if ch == ' ' {
            x += advance(ch);
            continue;
        }
        let Some((rows, w)) = glyph_rows(ch) else {
            x += advance(ch);
            continue;
        };
        for gy in 0..GLYPH_H {
            let bits = rows[gy as usize];
            if bits == 0 {
                continue;
            }
            for gx in 0..w {
                if bits & (1 << (15 - gx)) != 0 {
                    let px = x + gx;
                    let py = y0 + gy;
                    if px < mask_w && py < mask_h {
                        mask[(py * mask_w + px) as usize] = true;
                    }
                }
            }
        }
        x += w;
    }
}

fn painted(lines: &[String], scale: u32, colours: [&[u8]; 2], pitch: usize, base_w: u32, base_h: u32) -> Vec<u8> {
    let bytes = colours[0].len();
    let mut mask = vec![false; (base_w * base_h) as usize];
    for (row, line) in lines.iter().enumerate() {
        let y0 = RIM + row as u32 * LINE_H;
        if y0 + GLYPH_H > base_h {
            break;
        }
        paint_line(&mut mask, base_w, base_h, line, RIM, y0);
    }
    let width = base_w * scale;
    let height = base_h * scale;
    let mut out = vec![0; pitch * height as usize];
    for y in 0..base_h {
        for x in 0..base_w {
            let colour = colours[usize::from(mask[(y * base_w + x) as usize])];
            for i in 0..scale {
                let top = pitch * (y * scale + i) as usize;
                for j in 0..scale {
                    let at = top + ((x * scale + j) as usize) * bytes;
                    out[at..at + bytes].copy_from_slice(colour);
                }
            }
        }
    }
    out
}

struct Buffers {
    format: DXGI_FORMAT,
    scale: u32,
    base_w: u32,
    base_h: u32,
    pitch: u32,
    uploads: Vec<(ID3D12Resource, *mut u8)>,
    card: ID3D12Resource,
    turn: usize,
    fresh: bool,
    /// The card's buffer was copied into before (it is in the copy-source state;
    /// at first it is in the common state, promoted by the first copy).
    used: bool,
}

// SAFETY: free-threaded resources, and memory only written under the presenter's lock.
unsafe impl Send for Buffers {}

impl Buffers {
    fn new(host: &Host, format: DXGI_FORMAT, scale: u32, base_w: u32, base_h: u32) -> Option<Buffers> {
        let width = base_w * scale;
        let height = base_h * scale;
        let pitch = (width * colours(format)?[0].len() as u32).next_multiple_of(256);
        let bytes = u64::from(pitch) * u64::from(height);
        let uploads = (0..UPLOADS).map(|_| host.upload_buffer(bytes)).collect::<Option<Vec<_>>>()?;
        let heap = D3D12_HEAP_PROPERTIES { Type: D3D12_HEAP_TYPE_DEFAULT, ..Default::default() };
        let desc = D3D12_RESOURCE_DESC {
            Dimension: D3D12_RESOURCE_DIMENSION_BUFFER,
            Width: bytes,
            Height: 1,
            DepthOrArraySize: 1,
            MipLevels: 1,
            SampleDesc: DXGI_SAMPLE_DESC { Count: 1, Quality: 0 },
            Layout: D3D12_TEXTURE_LAYOUT_ROW_MAJOR,
            ..Default::default()
        };
        let mut card: Option<ID3D12Resource> = None;
        // SAFETY: plain creation of a buffer.
        unsafe {
            host.device
                .CreateCommittedResource(&heap, D3D12_HEAP_FLAG_NONE, &desc, D3D12_RESOURCE_STATE_COMMON, None, &mut card)
                .ok()?;
        }
        Some(Buffers { format, scale, base_w, base_h, pitch, uploads, card: card?, turn: 0, fresh: false, used: false })
    }

    fn write(&mut self, lines: &[String]) {
        let Some(colours) = colours(self.format) else { return };
        let picture = painted(lines, self.scale, colours, self.pitch as usize, self.base_w, self.base_h);
        self.turn = (self.turn + 1) % UPLOADS;
        // SAFETY: a mapped upload buffer of the picture's size, which the card read frames ago.
        unsafe { std::ptr::copy_nonoverlapping(picture.as_ptr(), self.uploads[self.turn].1, picture.len()) };
        self.fresh = true;
    }
}


/// The menu of a presenter.
pub(super) struct Menu {
    /// The values chosen, by item (as at start until changed).
    values: Vec<String>,
    /// The values at start.
    started: Vec<String>,
    /// The line picked: an item, or an action after them.
    at: usize,
    note: String,
    changed: bool,
    /// What the buffer holds: the frame-rate line, or (none) the menu's lines.
    painted: Option<String>,
    buffers: Option<Buffers>,
    failed: bool,
    /// The start's notice (the GPU, which frame generation runs and why not),
    /// shown at the top for its first seconds.
    notice: Option<Vec<String>>,
    notice_since: Option<std::time::Instant>,
}

impl Menu {
    pub(super) fn new() -> Menu {
        // Start the key thread now: F1 must be seen while the menu is closed.
        let _ = keys();
        // `VICTORY_MENU_OPEN=1`: shown from the start (to look at it in a run nobody presses keys in).
        if std::env::var_os("VICTORY_MENU_OPEN").is_some_and(|v| v == "1") {
            crate::SETTINGS_MENU_OPEN.store(true, Ordering::Relaxed);
        }
        let values: Vec<String> = ITEMS.iter().map(|i| get(i.var)).collect();
        let notice = {
            let lines = crate::streamline::notice();
            (!lines.is_empty()).then_some(lines)
        };
        Menu {
            started: values.clone(),
            values,
            at: 0,
            note: String::new(),
            changed: true,
            painted: None,
            buffers: None,
            failed: false,
            notice,
            notice_since: None,
        }
    }

    fn open() -> bool {
        crate::SETTINGS_MENU_OPEN.load(Ordering::Relaxed)
    }

    fn lines(&self) -> Vec<String> {
        let total = ITEMS.len() + ACTIONS.len();
        let first = self.at.saturating_sub(ROWS / 2).min(total.saturating_sub(ROWS));
        let room = BOX_W - 2 * RIM - text_width(TITLE) - text_width(TITLE_RIGHT);
        let gap = ((room / 8).max(1)) as usize;
        let title = format!("{}{}{}", TITLE, " ".repeat(gap), TITLE_RIGHT);
        let mut out = vec![title, HELP.to_owned(), String::new()];
        for row in first..(first + ROWS).min(total) {
            let cursor = if row == self.at { '>' } else { ' ' };
            let line = if let Some(item) = ITEMS.get(row) {
                let value = &self.values[row];
                let shown = shown_value(item, value);
                let mark = if *value != self.started[row] { if live(item) { MARKS[0] } else { MARKS[1] } } else if live(item) { MARKS[0] } else { "" };
                format!("{cursor} {}< {shown} >{mark}", pad_label(item.label))
            } else {
                format!("{cursor} {}", ACTIONS[row - ITEMS.len()])
            };
            out.push(line);
        }
        while out.len() < 3 + ROWS {
            out.push(String::new());
        }
        out.push(String::new());
        let about = if self.at == ITEMS.len() + PRELOAD { ABOUT_PRELOAD } else { [""; 3] };
        out.extend(about.iter().map(|l| (*l).to_owned()));
        out.push(if self.note.is_empty() { NOTE.to_owned() } else { self.note.clone() });
        out.push(REPO.to_owned());
        out
    }

    /// Changes item `i` by `step` (+1 / -1) through its values.
    fn change(&mut self, i: usize, step: isize) {
        let item = &ITEMS[i];
        let fsr = ITEMS
            .iter()
            .position(|it| it.var == "VICTORY_MENU_FG_TYPE")
            .and_then(|k| self.values.get(k))
            .is_some_and(|v| v == "fsr");
        let n = if item.var == "VICTORY_MENU_FRAMEGEN" && fsr { 2 } else { item.values.len() as isize };
        let now = index_of(item, &self.values[i]).map_or(-1, |x| x as isize);
        let next = if now < 0 { if step > 0 { 0 } else { n - 1 } } else { (now + step).rem_euclid(n) };
        self.values[i] = item.values[next as usize].0.to_owned();
        if live(item) {
            self.apply_live(i);
        }
        self.note.clear();
    }

    /// A setting the build reads at each use: changed in this run's environment at once.
    fn apply_live(&self, i: usize) {
        let (var, value) = (ITEMS[i].var, &self.values[i]);
        // SAFETY: the variables changed here are read by this build with
        // std::env::var at each use; Windows' environment block is locked by
        // the process heap's routines, and std holds its own lock.
        unsafe {
            if value.is_empty() {
                std::env::remove_var(var);
            } else {
                std::env::set_var(var, value);
            }
        }
        match var {
            // Off (0) or the frames shown for each one rendered, from the next present on.
            "VICTORY_MENU_FRAMEGEN" => crate::streamline::set_framegen(value.parse().unwrap_or(0)),
            "VICTORY_FPS_LINE" => fps_line_on().store(value != "0", Ordering::Relaxed),
            "VICTORY_PANEL" => super::panel::shown().store(value == "1", Ordering::Relaxed),
            _ => {}
        }
    }

    /// Writes the changed values over those in the settings file.
    fn save(&mut self) -> bool {
        let Some(path) = std::env::var_os("VICTORY_MENU_FILE") else {
            self.note = "没有设置文件：请用「启动.bat」启动（菜单设置才存得下）".to_owned();
            return false;
        };
        let mut kept: Vec<(String, String)> = std::fs::read_to_string(&path)
            .unwrap_or_default()
            .lines()
            .filter_map(|l| l.split_once('=').map(|(k, v)| (k.trim().to_owned(), v.trim().to_owned())))
            .filter(|(k, _)| k.starts_with("VICTORY_"))
            .collect();
        for (i, item) in ITEMS.iter().enumerate() {
            if self.values[i] == self.started[i] {
                continue;
            }
            kept.retain(|(k, _)| k != item.var);
            kept.push((item.var.to_owned(), self.values[i].clone()));
        }
        let mut text = String::from("# 由 F1 菜单保存；每次启动时覆盖 play 的设置（空值 = 不设置）。\r\n");
        for (k, v) in &kept {
            text.push_str(&format!("{k}={v}\r\n"));
        }
        match std::fs::write(&path, text) {
            Ok(()) => {
                tracing::info!(path = %std::path::Path::new(&path).display(), "settings menu: saved");
                self.started = self.values.clone();
                self.note = "已保存：下次启动生效".to_owned();
                true
            }
            Err(e) => {
                tracing::warn!(error = %e, "settings menu: not saved");
                self.note = "保存失败：写不了设置文件".to_owned();
                false
            }
        }
    }

    /// Starts the launcher again in a new console, a few seconds on, and ends this run.
    /// `preload`: the launcher makes every shader first (its `-Preload`, for that start alone).
    fn restart(&mut self, preload: bool) {
        let Some(play) = std::env::var_os("VICTORY_MENU_PLAY") else {
            self.note = "已保存：请自己重新启动启动器".to_owned();
            return;
        };
        let play = play.to_string_lossy().replace('\'', "''");
        let args = get("VICTORY_MENU_ARGS");
        let command = format!("Start-Sleep 3; & '{play}' {args}{}", if preload { " --preload" } else { "" });
        match new_console(&format!("powershell.exe -NoProfile -ExecutionPolicy Bypass -Command \"{}\"", command.replace('"', "\\\""))) {
            Ok(()) => {
                tracing::info!(command, preload, "settings menu: restarting");
                // Ended at once: std::process::exit runs the DLLs' unloading, which with
                // Streamline loaded did not come back (a windowless leftover process).
                // SAFETY: this process, with nothing of its own left to save.
                unsafe {
                    use windows_sys::Win32::System::Threading::{GetCurrentProcess, TerminateProcess};
                    TerminateProcess(GetCurrentProcess(), 0);
                }
                std::process::exit(0);
            }
            Err(e) => {
                tracing::warn!(error = %e, "settings menu: restart failed");
                self.note = "已保存，但自动重启失败".to_owned();
            }
        }
    }

    /// Removes the settings file: the launcher's own settings at the next start.
    fn reset(&mut self) {
        if let Some(path) = std::env::var_os("VICTORY_MENU_FILE") {
            let _ = std::fs::remove_file(path);
        }
        self.note = "已恢复默认：下次启动生效".to_owned();
    }

    /// A frame was presented: the keys pressed since the last one.
    pub(super) fn frame(&mut self) {
        let pressed = std::mem::take(&mut *keys().lock().unwrap_or_else(|e| e.into_inner()));
        if pressed.is_empty() {
            return;
        }
        let total = ITEMS.len() + ACTIONS.len();
        for vk in pressed {
            let open = Self::open();
            if vk == VK_F1 || (open && vk == VK_ESCAPE) {
                crate::SETTINGS_MENU_OPEN.store(!open && vk == VK_F1, Ordering::Relaxed);
                self.note.clear();
                self.changed = true;
                continue;
            }
            if !open {
                continue;
            }
            // Only an Enter right after the first one starts a preload.
            let confirmed = self.note == CONFIRM_PRELOAD;
            if confirmed {
                self.note.clear();
            }
            match vk {
                VK_UP => self.at = (self.at + total - 1) % total,
                VK_DOWN => self.at = (self.at + 1) % total,
                VK_LEFT if self.at < ITEMS.len() => self.change(self.at, -1),
                VK_RIGHT if self.at < ITEMS.len() => self.change(self.at, 1),
                VK_RETURN if self.at < ITEMS.len() => self.change(self.at, 1),
                VK_RETURN => match self.at - ITEMS.len() {
                    0 => {
                        if self.save() {
                            self.restart(false);
                        }
                    }
                    1 => {
                        self.save();
                    }
                    PRELOAD if !confirmed => self.note = CONFIRM_PRELOAD.to_owned(),
                    PRELOAD => {
                        if self.save() {
                            self.restart(true);
                        }
                    }
                    3 => self.reset(),
                    _ => crate::SETTINGS_MENU_OPEN.store(false, Ordering::Relaxed),
                },
                _ => {}
            }
            self.changed = true;
        }
    }

    /// Records the copy of the box onto `back` (in the copy-destination state).
    pub(super) fn draw(&mut self, host: &Host, list: &HostList, back: &ID3D12Resource, (width, height): (u32, u32), format: DXGI_FORMAT) {
        if self.failed {
            return;
        }
        // Closed: the start's notice at the top, else the frame-rate line in the top left
        // corner, if it is wanted and there is a rate.
        let open = Self::open();
        const NOTICE_FOR: std::time::Duration = std::time::Duration::from_secs(30);
        if !open && self.notice.is_some() {
            let over = match self.notice_since {
                Some(since) => since.elapsed() > NOTICE_FOR,
                None => {
                    self.notice_since = Some(std::time::Instant::now());
                    false
                }
            };
            if over {
                self.notice = None;
                self.notice_since = None;
                self.changed = true;
            }
        }
        let notice = if open { None } else { self.notice.clone() };
        let line = if open || notice.is_some() { None } else { fps_line() };
        if !open && notice.is_none() && line.is_none() {
            return;
        }
        // Our own copies are not part of a recorded frame (the recorder is in diagnostics builds).
        #[cfg(feature = "diagnostics")]
        let _ours = crate::replay::record::unrecorded();
        let scale = (height / 540).max(1);
        let (base_w, base_h) = if let Some(lines) = &notice {
            let width = lines.iter().map(|l| text_width(l)).max().unwrap_or(0) + 2 * RIM;
            (width, lines.len() as u32 * LINE_H + 2 * RIM)
        } else if let Some(l) = &line {
            (text_width(l) + 2 * RIM, LINE_H + 2 * RIM)
        } else {
            (BOX_W + 2 * RIM, LINES * LINE_H + 2 * RIM)
        };
        if self.buffers.as_ref().is_none_or(|b| (b.format, b.scale, b.base_w, b.base_h) != (format, scale, base_w, base_h)) {
            std::mem::forget(self.buffers.take());
            self.buffers = Buffers::new(host, format, scale, base_w, base_h);
            self.failed = self.buffers.is_none();
            self.changed = true;
        }
        if self.painted != line {
            self.painted = line.clone();
            self.changed = true;
        }
        let lines = if self.changed {
            Some(if let Some(n) = &notice {
                n.clone()
            } else if let Some(l) = &line {
                vec![l.clone()]
            } else {
                self.lines()
            })
        } else {
            None
        };
        let Some(buffers) = &mut self.buffers else { return };
        if let Some(lines) = lines {
            self.changed = false;
            buffers.write(&lines);
        }
        // The whole box in the middle, or of it the first line's part in the corner.
        let (w, h) = (base_w * scale, base_h * scale);
        let (w, h) = (w.min(width), h.min(height));
        let (x, y) = if notice.is_some() {
            ((width - w) / 2, 24 * scale)
        } else if line.is_some() {
            (0, 0)
        } else {
            ((width - w) / 2, (height - h) / 2)
        };
        let list = &list.list;
        // SAFETY: an open list and live resources; the box lies within both.
        unsafe {
            if std::mem::take(&mut buffers.fresh) {
                if std::mem::replace(&mut buffers.used, true) {
                    list.ResourceBarrier(&[transition(&buffers.card, D3D12_RESOURCE_STATE_COPY_SOURCE, D3D12_RESOURCE_STATE_COPY_DEST)]);
                }
                list.CopyResource(&buffers.card, &buffers.uploads[buffers.turn].0);
                list.ResourceBarrier(&[transition(&buffers.card, D3D12_RESOURCE_STATE_COPY_DEST, D3D12_RESOURCE_STATE_COPY_SOURCE)]);
            }
            let from = D3D12_TEXTURE_COPY_LOCATION {
                pResource: std::mem::transmute_copy(&buffers.card),
                Type: D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT,
                Anonymous: D3D12_TEXTURE_COPY_LOCATION_0 {
                    PlacedFootprint: D3D12_PLACED_SUBRESOURCE_FOOTPRINT {
                        Offset: 0,
                        Footprint: D3D12_SUBRESOURCE_FOOTPRINT { Format: format, Width: base_w * scale, Height: base_h * scale, Depth: 1, RowPitch: buffers.pitch },
                    },
                },
            };
            let to = D3D12_TEXTURE_COPY_LOCATION {
                pResource: std::mem::transmute_copy(back),
                Type: D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX,
                Anonymous: D3D12_TEXTURE_COPY_LOCATION_0 { SubresourceIndex: 0 },
            };
            let part = D3D12_BOX { left: 0, top: 0, front: 0, right: w, bottom: h, back: 1 };
            list.CopyTextureRegion(&to, x, y, 0, &from, Some(&part));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample() -> Menu {
        let values: Vec<String> = ITEMS
            .iter()
            .map(|i| i.values.first().map(|v| v.0.to_owned()).unwrap_or_default())
            .collect();
        Menu {
            started: values.clone(),
            values,
            at: 0,
            note: String::new(),
            changed: false,
            painted: None,
            buffers: None,
            failed: false,
            notice: None,
            notice_since: None,
        }
    }

    /// 每一行都放得进框，且每个字符（中文/英文）都有字模——汉化完整性检查。
    #[test]
    fn every_line_fits_and_every_character_has_a_picture() {
        let mut menu = sample();
        for at in 0..ITEMS.len() + ACTIONS.len() {
            menu.at = at;
            for line in menu.lines() {
                assert!(text_width(&line) <= BOX_W - 2 * RIM, "too wide: {line}");
                for c in line.chars() {
                    assert!(glyph_rows(c).is_some(), "no glyph for U+{:04X} in: {line}", c as u32);
                }
            }
        }
        for action in ACTIONS {
            for c in action.chars() {
                assert!(glyph_rows(c).is_some(), "no glyph for U+{:04X} in: {action}", c as u32);
            }
        }
        for line in ABOUT_PRELOAD {
            for c in line.chars() {
                assert!(glyph_rows(c).is_some(), "no glyph for U+{:04X} in: {line}", c as u32);
            }
        }
        for c in CONFIRM_PRELOAD.chars() {
            assert!(glyph_rows(c).is_some(), "no glyph for U+{:04X}", c as u32);
        }
    }

    /// 动作列表与预载说明：说明只在「预载着色器」这一行出现。
    #[test]
    fn the_preload_hint_is_shown_only_while_picked() {
        let mut menu = sample();
        assert_eq!(ACTIONS[PRELOAD], "预载着色器(重启游戏)");
        assert!(text_width(CONFIRM_PRELOAD) <= BOX_W - 2 * RIM);
        for at in 0..ITEMS.len() + ACTIONS.len() {
            menu.at = at;
            let lines = menu.lines();
            assert_eq!(lines.len(), LINES as usize);
            let n = lines.len();
            let about = &lines[n - 5..n - 2];
            if at == ITEMS.len() + PRELOAD {
                assert_eq!(about, ABOUT_PRELOAD);
            } else {
                assert!(about.iter().all(String::is_empty), "{about:?}");
            }
            assert_eq!(lines[n - 2], NOTE);
            assert_eq!(lines[n - 1], REPO);
        }
    }

    /// 左右键在选项值之间循环。
    #[test]
    fn values_cycle_both_ways() {
        let mut menu = sample();
        let n = ITEMS[0].values.len();
        for _ in 0..n {
            menu.change(0, 1);
        }
        assert_eq!(menu.values[0], ITEMS[0].values[0].0);
        menu.change(0, -1);
        assert_eq!(menu.values[0], ITEMS[0].values[n - 1].0);
    }

    /// 选了 FSR 后端时，帧生成这一行只有 关 / 2X 两档。
    #[test]
    fn fsr_offers_two_frame_generation_values() {
        let mut menu = sample();
        let fg = ITEMS.iter().position(|i| i.var == "VICTORY_MENU_FRAMEGEN").unwrap();
        let kind = ITEMS.iter().position(|i| i.var == "VICTORY_MENU_FG_TYPE").unwrap();
        menu.values[kind] = "fsr".to_owned();
        menu.values[fg] = "2".to_owned();
        menu.change(fg, 1);
        assert_eq!(menu.values[fg], "0");
        menu.change(fg, 1);
        assert_eq!(menu.values[fg], "2");
    }
}
