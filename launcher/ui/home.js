// GTA6 CN · Victory, the player's launcher. Talks to the host (App.cs) with web messages:
// launch.* (run, warm, settings, PC checks), win.* (the window's buttons), the rest go to the save manager.
const $ = (s) => document.querySelector(s);
const $$ = (s) => [...document.querySelectorAll(s)];
const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);
const send = (m) => {
  if (window.chrome?.webview) window.chrome.webview.postMessage(m);
  else window.webkit.messageHandlers.vism.postMessage(JSON.stringify(m));
};
const gb = (b) => (b / 1073741824).toFixed(b >= 10 * 1073741824 ? 0 : 1) + ' GB';
const fmtSize = (b) => b >= 1048576 ? (b / 1048576).toFixed(1) + ' MB' : Math.max(1, Math.round(b / 1024)) + ' KB';
const num = (n) => Number(n).toLocaleString();
const folder = (p) => String(p || '').replace(/[\\/][^\\/]*$/, '');
const crash = (c) => (c < 0 || c > 255) ? '0x' + (c >>> 0).toString(16).toUpperCase() : String(c);
function ago(iso) {
  const t = Date.parse(String(iso).replace(' ', 'T'));
  if (!t) return '';
  const m = (Date.now() - t) / 60000;
  if (m < 1) return 'just now';
  if (m < 60) return Math.round(m) + ' min ago';
  if (m < 48 * 60) return Math.round(m / 60) + ' h ago';
  return Math.round(m / 1440) + ' days ago';
}

const ID = 'public';
let A = { os: 'windows' };              // the app
let S = { settings: {}, history: {} };  // settings, running state, history
let PC = null;                          // the PC checks
let SV = null;                          // the save manager's list
let job = null;                         // a step running (warm-up)
const freshWarm = () => ({ count: 0, secs: 0, total: null, samples: [] });
let warm = freshWarm();                 // the warm-up's progress, from its output (total: "to make", null before it says)

// (Victory) the warm-up's progress, worked out once for every place that shows it
function warmProgress() {
  const w = warm;
  if (w.total === null) return { pct: null, zero: false, line: '正在准备着色器…', value: '预热中…', small: '启动中' };
  if (w.total === 0) {
    const t = '这个版本已经预热完成';
    return { pct: 100, zero: true, line: t, value: '已准备', small: t };
  }
  const pct = Math.min(100, Math.floor(100 * w.count / w.total));
  const left = warmLeft();
  const of = `${num(w.count)} of ${num(w.total)}`;
  return { pct, zero: false, line: `正在准备着色器 · ${pct}% · ${of}${left ? ' · ' + left : ''}`,
    value: `预热中 · ${pct}%`, small: left ? `${of} · ${left}` : of };
}
// time left from the rate over the recent part of the run: its second half, at most the last 90 seconds
// (the first pipelines are the slow ones); nothing before 20 s and 20 made
function warmLeft() {
  const s = warm.samples;
  if (s.length < 2) return '';
  const last = s[s.length - 1];
  if (last.t < 20 || last.c < 20) return '';
  const span = Math.min(90, last.t / 2);
  let i = s.findIndex((x) => last.t - x.t <= span);
  if (i < 0 || i === s.length - 1) i = s.length - 2;
  const first = s[i];
  if (last.t - first.t < 5 || last.c <= first.c) return '';
  const secs = (warm.total - last.c) / ((last.c - first.c) / (last.t - first.t));
  if (secs < 60) return 'under a minute left';
  const m = Math.round(secs / 60);
  if (m < 60) return `about ${m} min left`;
  const h = Math.floor(m / 60), r = m % 60;
  return `about ${h} h${r ? ' ' + r + ' min' : ''} left`;
}
// the bars: filled to the percentage once there is one, the moving stripe before
function fillBars(pct) {
  $$('#warmBar .bar i, #w2 .bar i').forEach((i) => {
    i.classList.toggle('fill', pct !== null);
    i.style.width = pct !== null ? pct + '%' : '';
  });
}
let view = 'home', section = 'general', step = 0;
let REL = {};                           // this release: version, commit, date
const st = (k, d) => S.settings[k] ?? d;
const set = (values) => { Object.assign(S.settings, values); send({ cmd: 'launch.set', values }); };

// ---------------- the switches this app changes for the player ----------------
// "Save video memory" (the host's vramSaver): the team's set is tuned for 16 GB cards; under that,
// two switches come down for every run and warm-up.
const saverOn = () => !!st('vramSaver', false);
function setSaver(on) { set({ vramSaver: on }); }

// ---------------- quiet while busy: no animation or blur competes with the game or the warm-up ----------------
function quiet() { document.body.classList.toggle('quiet', !!(S.running || job)); }

// ---------------- home ----------------
function hist() { return S.history?.[ID] || {}; }
function renderHome() {
  const gameOk = !!S.gameOk, filesOk = !!S.filesOk, running = !!S.running;
  const h = hist(), runs = h.runs || [], last = runs[runs.length - 1];
  const eye = $('#heroEye');
  eye.className = 'eyebrow';
  if (running) eye.textContent = 'PLAYING';
  else if (job) eye.textContent = '正在准备着色器';
  else if (!gameOk || !filesOk) eye.textContent = '';   // the bottom-right corner says it, with the Set up button
  else eye.textContent = 'READY TO PLAY';
  $('#hero').classList.toggle('playing', running);
  $('#heroSub').textContent = gameOk && filesOk ? `Your dump · ${folder(st('game', ''))}` : '';

  const play = $('#playBtn');
  play.classList.toggle('stop', running);
  play.querySelector('span').textContent = running ? '停止' : '开始';
  play.querySelector('svg').innerHTML = running ? '<rect x="6" y="6" width="12" height="12" rx="2"/>' : '<path d="M7 4l13 8-13 8z"/>';
  play.disabled = !running && (!gameOk || !filesOk || !!job);
  $('#mode').value = st('seriesX', false) ? 'x' : 's';
  $('#mode').disabled = running;
  const warmBtn = $('#warmBtn');
  warmBtn.textContent = job ? 'Cancel' : '预热着色器';
  warmBtn.disabled = running || (!job && (!gameOk || !filesOk || S.shaderState === 'empty'));
  warmBtn.title = !job && S.shaderState === 'empty' ? 'Play once first: the game lists its shaders the first time it runs' : '';
  $('#warmBar').hidden = !job;
  const wp = warmProgress();
  $('#warmText').textContent = wp.line;
  const noDll = false;   // Series S uses the title's own upscaler: nothing to add
  // the note keeps its line when empty, so the buttons above it never move
  $('#heroNote').classList.toggle('off', !noDll || running);
  const setup = !gameOk || !filesOk;
  $('#setupCorner').hidden = !setup || running || !!job;
  // 预热着色器 can't run before set-up anyway: its place goes to SET UP NEEDED, so that fits on the Play row
  warmBtn.hidden = setup && !running && !job;
  renderDlssHome(setup && !running && !job);
  $('#hero').classList.toggle('needsetup', setup && !running && !job);
  navBadges();
  $('#setAlert').hidden = !setup;
  $('#heroNote').textContent = '';

  // cards
  const c = (id, v, s, cls = '') => { $(id).textContent = v; $(id).className = 'v ' + cls; $(id + 'S').textContent = s; };
  if (last) c('#cSession', last.minutes < 1 ? 'Under a minute' : `${last.minutes} min`,
    `${ago(last.start)} · ${last.stopped ? 'stopped' : last.code === 0 ? 'no crash' : 'crashed (' + crash(last.code) + ')'}`, last.stopped || last.code === 0 ? '' : 'warn');
  else c('#cSession', '还没有', '点开始游戏');
  // (Victory) the host judges the warm-up against this game build and the translator's switches
  // and, when it could ask (victory.exe warm --count), by how many are still to make: under 1,000 is warm
  const ss = S.shaderState, n = typeof S.toMake === 'number' ? S.toMake : null;
  const warmSub = () => (h.warmAt ? (st('warmCount', 0) ? `${num(st('warmCount', 0))} shaders ready · ${ago(h.warmAt)}` : `ready · ${ago(h.warmAt)}`) : 'nothing much to prepare')
    + (n > 0 ? ` · ${num(n)} small ones are made as you play` : '');
  const toDo = n !== null ? `${num(n)} shaders to prepare` : '';
  if (job) c('#cShaders', wp.value, wp.small, 'ok');
  // a new PC: the game lists its shaders the first time it runs, so there is nothing to warm before that
  else if (ss === 'empty') c('#cShaders', '未预热', 'Play once so the game lists its shaders, then warm them here');
  else if (ss === 'warm' && n !== null) c('#cShaders', '已预热', warmSub(), 'ok');
  else if (!h.warmAt) c('#cShaders', '未预热', toDo ? `${toDo}: warm it once for a smooth first run` : '预热一次，首局更顺');
  else if (h.warmCode !== 0) c('#cShaders', 'Failed', 'Try 预热着色器 again', 'bad');
  else if (ss === 'build') c('#cShaders', '需要重新预热', toDo ? `New game build · ${toDo}` : 'New game build: warm again', 'warn');
  else if (ss === 'flags') c('#cShaders', '需要重新预热', toDo ? `Settings changed · ${toDo}` : 'Settings changed: warm again', 'warn');
  else if (ss === 'out') c('#cShaders', '需要重新预热', toDo || 'Warm again', 'warn');
  else c('#cShaders', '已预热', warmSub(), 'ok');
  if (PC) c('#cPc', PC.gpu || 'Graphics card', [PC.driver && '驱动 ' + PC.driver, PC.vram && gb(PC.vram)].filter(Boolean).join(' · ') || 'details unavailable');

  renderChecks();
  renderSaveTiles();
  fillBars(job ? wp.pct : null);
  quiet();
}

function checksList() {
  const L = [];
  L.push(['游戏文件', S.gameOk ? ['已找到', 'ok'] : ['未设置', 'bad']]);
  L.push(['启动器文件', S.filesOk ? ['已找到', 'ok'] : ['缺少', 'bad']]);
  if (PC) {
    if (PC.vram) L.push(['显存', PC.vram >= 15e9 ? [gb(PC.vram), 'ok'] : [`${gb(PC.vram)} · ${saverOn() ? '省显存开' : '建议开省显存'}`, saverOn() ? 'ok' : 'warn']]);
    if (PC.ram) L.push(['可用内存', PC.ramFree >= 16e9 ? [`${gb(PC.ramFree)} 可用`, 'ok'] : [`16 GB needed · ${gb(PC.ramFree)} 可用`, 'warn']]);
    if (PC.disk >= 0) L.push(['Disk space', PC.disk >= 10e9 ? ['OK', 'ok'] : [`${gb(PC.disk)} free`, 'warn']]);
  }
  return L;
}
function renderChecks() {
  $('#checks').innerHTML = checksList().map(([k, [v, cls]]) => `<div><span>${esc(k)}</span><span class="${cls}">${esc(v)}</span></div>`).join('');
}

function renderSaveTiles() {
  const box = $('#saveTiles');
  if (!SV) { box.innerHTML = ''; return; }
  const mine = SV.spots.filter((s) => !s.auto).slice(0, 2).map((s, i) => ({ ...s, label: i === 0 ? `latest · ${ago(s.kept)}` : ago(s.kept) }));
  const team = SV.team.slice(0, 3 - mine.length).map((s) => ({ ...s, label: 'team save' }));
  box.innerHTML = [...mine, ...team].map((s, i) => `<button class="st${i === 0 && mine.length ? ' cur' : ''}" data-view="saves"><b>${esc(s.name)}</b><div>${esc(s.label)}</div></button>`).join('')
    + '<button class="st add" id="importTile">+ Import a save</button>';
}

// ---------------- this release ----------------
const verText = () => REL.version ? 'v' + REL.version : REL.commit ? 'build ' + REL.commit : '';
function renderRelease() {
  $('#heroVer').textContent = verText();
  // the version is always on the home screen: a release's number, a team build's commit, or "dev build"
  $('#verPill').textContent = REL.version ? verText() + ' · release' : verText() || 'dev build';
}

// ---------------- saves page (the save manager) ----------------
function renderSaves(m) {
  SV = m;
  $('#chooseSaveFolder').hidden = !m.canChooseSaveFolder;
  $('#savePath').hidden = !m.canChooseSaveFolder;
  $('#savePath').textContent = m.saveDirectory || 'Select the game’s saves folder to load a save.';
  $('#svNow').innerHTML = m.found
    ? `<div class="sv-row"><div><b>Current game save</b><span>Last written ${esc(m.newest)} · ${fmtSize(m.size)}</span></div>
        ${m.running ? '<span class="warn">game running: loading is off until you close it</span>' : ''}
        <button class="mini ghost" data-sv="share" data-kind="current">Share</button></div>`
    : '<div class="sv-row"><div><b>No save yet</b><span>Play until the game autosaves, or load a saved spot below.</span></div></div>';
  $('#svNote').textContent = m.note || '';
  $('#svNote').classList.toggle('bad', m.ok === false);
  $$('[data-sv="fresh"]').forEach((x) => { x.disabled = !!m.running; });
  const row = (s, kind) => `<li class="sv-item${s.auto ? ' auto' : ''}${kind === 'team' ? ' team' : ''}">
      <div class="sv-nm"><b>${esc(s.name)}</b><span>${s.note ? esc(s.note) + ' · ' : ''}game saved ${esc(s.gameTime)} · ${fmtSize(s.size)}</span></div>
      <div class="acts">
        <button class="mini" data-sv="load" data-kind="${kind}" data-name="${esc(s.name)}" ${m.running ? 'disabled title="Close the game first"' : ''}>Load</button>
        <button class="mini ghost" data-sv="share" data-kind="${kind}" data-name="${esc(s.name)}">Share</button>
        ${kind === 'spot' ? `<button class="mini ghost" data-sv="delete" data-name="${esc(s.name)}">Delete</button>` : ''}
      </div></li>`;
  const mine = m.spots.filter((s) => !s.auto), autos = m.spots.filter((s) => s.auto);
  $('#svList').innerHTML =
    (m.team.length ? `<div class="ogroup">Team saves</div><ul class="sv-list">${m.team.map((s) => row(s, 'team')).join('')}</ul>` : '')
    + '<div class="ogroup">Your spots and imports</div>'
    + (mine.length ? `<ul class="sv-list">${mine.map((s) => row(s, 'spot')).join('')}</ul>` : '<p class="sub">None yet. Name your current save above, or import one.</p>')
    + (autos.length ? `<div class="ogroup">Automatic backups (before each load, the last 5)</div><ul class="sv-list">${autos.map((s) => row(s, 'spot')).join('')}</ul>` : '');
  renderSaveTiles();
}
function armed(btn, label) {
  if (btn.dataset.armed) return true;
  btn.dataset.armed = '1'; const old = btn.textContent; btn.textContent = label; btn.classList.add('armed');
  setTimeout(() => { if (btn.isConnected) { delete btn.dataset.armed; btn.textContent = old; btn.classList.remove('armed'); } }, 4000);
  return false;
}

// ---------------- views and settings: transitions ----------------
function show(v) {
  if (v === view) return;
  view = v;
  $$('.rb[data-view]').forEach((b) => b.classList.toggle('on', b.dataset.view === v));
  $$('.view').forEach((s) => s.classList.toggle('on', s.id === 'v-' + v));
  if (v === 'saves') send({ cmd: 'list' });
}
function openSettings(sec) {
  if (sec) section = sec;
  renderSettings(true);
  $('#settings').classList.add('open');
  $('#settings').setAttribute('aria-hidden', 'false');
  $('#shell').classList.add('behind');
}
function closeSettings() {
  $('#settings').classList.remove('open');
  $('#settings').setAttribute('aria-hidden', 'true');
  $('#shell').classList.remove('behind');
  $('#q').value = '';
}

// a red ! where set-up needs something: on the setting itself and on its section in the menu
const bang = '<span class="bang" title="Needs attention" aria-label="Needs attention">!</span>';
function navBadges() {
  const general = !S.gameOk || !S.filesOk;
  $$('.sn').forEach((b) => {
    const want = b.dataset.sec === 'general' && general, has = b.querySelector('.bang');
    if (want && !has) b.insertAdjacentHTML('beforeend', bang);
    if (!want && has) has.remove();
  });
}
const tog = (key, on, label) => `<button class="tog${on ? ' on' : ''}" data-tog="${key}" role="switch" aria-checked="${on}" aria-label="${esc(label)}"></button>`;
function row(title, help, control, extra = '') {
  return `<div class="srow" data-search="${esc((title + ' ' + help).toLowerCase())}"><div class="t"><b>${title}</b><small>${help}</small>${extra}</div>${control}</div>`;
}
const pathCode = (key) => st(key, '') ? `<code>${esc(st(key, ''))}</code>` : '';
// (Victory) DLSS and frame generation: shown on an NVIDIA RTX card only (the PC check's card name).
// RTX 40 and 50 generate frames, only 50 more than one between two; RTX 20 and 30 upscale only.
let SL = null;   // the last word from Get NVIDIA's files (progress, done, error)
function nvidiaRows() {
  const gen = PC.rtx, fg = +st('framegen', 0), dlss = !!st('dlss', false), sl = S.sl || {};
  const opts = [[0, 'Off'], [1, '2x'], [2, '3x'], [3, '4x'], [5, '6x']];
  const seg = `<div class="seg" role="radiogroup" aria-label="Frame generation">${opts.map(([n, l]) =>
    `<button data-fg="${n}" class="${fg === n ? 'on' : ''}" ${n > 0 && (gen < 40 || (n > 1 && gen < 50)) ? 'disabled' : ''}>${l}</button>`).join('')}</div>`;
  const busy = !!sl.busy || SL?.state === 'progress';
  const wanted = fg > 0 || dlss;
  const ready = (fg === 0 || sl.frameOk) && (!dlss || sl.dlssOk);
  const status = SL ? `<small class="${SL.state === 'done' ? 'ok' : SL.state === 'error' ? 'bad' : ''}">${esc(SL.text)}</small>`
    : !wanted ? ''
    : ready ? `<small class="ok">NVIDIA-signed files ready in ${esc(sl.dir)}</small>`
    : `<small class="warn">Not there yet: until they are, Play runs without DLSS.</small>`;
  return [
    row('Frame generation (DLSS)', gen >= 50 ? `Frames DLSS makes between two of the game’s (${esc(PC.gpu)}: up to 6x)`
      : gen >= 40 ? `Frames DLSS makes between two of the game’s (${esc(PC.gpu)}: 2x; more needs an RTX 50)` : `Needs an RTX 40 or 50 card (yours: ${esc(PC.gpu)})`, seg),
    row('DLSS upscaling', 'DLSS takes over the game’s own upscaler; the FidelityFX DLL above is then not used', tog('dlss', dlss, 'DLSS upscaling')),
    row('Get NVIDIA’s files', '从 NVIDIA 的 GitHub 下载 Streamline SDK（276 MB），保留 10–67 MB 在 <code>%LOCALAPPDATA%\\Victory\\streamline</code>; a DLL is kept only if NVIDIA signed it. Only when you press the button.',
      `<button class="mini" data-act="getSl" ${busy || S.running ? 'disabled' : ''}>${busy ? 'Working…' : ready && wanted ? 'Check again' : 'Get NVIDIA’s files'}</button>`, status),
    row('Or a folder of your own', 'A folder that already holds NVIDIA’s Streamline DLLs (sl.interposer.dll and the others); each must be signed by NVIDIA',
      `<div class="acts"><button class="mini" data-pickdir="streamlineDir" data-title="A folder with NVIDIA’s Streamline DLLs">Choose…</button>${st('streamlineDir', '') ? '<button class="mini ghost" data-clear="streamlineDir">Clear</button>' : ''}</div>`,
      pathCode('streamlineDir')),
  ];
}

// ---------------- (Victory) DLSS on the home card, beside 预热着色器, and its dialog ----------------
// The same settings as the rows above (framegen, dlss): either place changes both.
const rtxGen = () => (A.os === 'windows' && PC?.rtx >= 20 && S.sl) ? PC.rtx : 0;
// the files the home control needs: frame generation's on RTX 40 and 50, upscaling's on RTX 20 and 30
const dlssReady = () => { const g = rtxGen(); return !!g && (g >= 40 ? !!S.sl.frameOk : !!S.sl.dlssOk); };
const dlssBusy = () => !!S.sl?.busy || SL?.state === 'progress';
const dlssPct = () => SL?.total ? Math.min(100, Math.floor(100 * (SL.got || 0) / SL.total)) : 0;
// frames generated (framegen) on RTX 40 and 50, above 2x on RTX 50 only; upscaling on or off on RTX 20 and 30
function dlssChoices() {
  const g = rtxGen();
  if (g < 40) return [['off', 'Off'], ['up', 'Upscaling']];
  return [[0, 'Off'], [1, '2x'], ...(g >= 50 ? [[2, '3x'], [3, '4x'], [5, '6x']] : [])].map(([n, l]) => [String(n), l]);
}
function dlssValue() {
  const g = rtxGen();
  if (g < 40) return st('dlss', false) ? 'up' : 'off';
  const fg = +st('framegen', 0);
  return String(g < 50 && fg > 1 ? 1 : fg);   // an RTX 40 runs anything above 2x at 2x (the host holds it there)
}
// frame generation was tested together with DLSS upscaling: picking it turns upscaling on too when its files
// are there (Settings › Graphics can turn it off again); Off leaves upscaling as it is
function dlssChoose(v) {
  if (v === 'off' || v === 'up') set({ dlss: v === 'up' });
  else { const n = +v; set(n > 0 && S.sl?.dlssOk ? { framegen: n, dlss: true } : { framegen: n }); }
  renderHome();
  if ($('#settings').classList.contains('open')) renderSettings();
  if (dlg) renderDlg();
}
let dlssOpts = '';   // the dropdown's options as last written (rewritten only when they change)
function renderDlssHome(hide) {
  const g = rtxGen(), btn = $('#dlssBtn'), sel = $('#dlssSel');
  const busy = dlssBusy(), ready = dlssReady() && !busy;
  btn.hidden = !g || hide || ready;
  sel.hidden = !g || hide || !ready;
  if (!g) return;
  btn.disabled = busy || !!S.running;
  btn.textContent = busy ? `DLSS ${dlssPct()}%` : 'Get DLSS';
  const opts = dlssChoices().map(([v, l]) => `<option value="${v}">DLSS · ${l}</option>`).join('');
  if (opts !== dlssOpts) { sel.innerHTML = opts; dlssOpts = opts; }
  sel.value = dlssValue();
  sel.disabled = !!S.running;
}

let dlg = null;   // the dialog's step: 'ask', 'run', 'choose', 'error'; null while it is closed
function openDlg(step) { dlg = step; $('#dlssDlg').hidden = false; renderDlg(); }
function closeDlg() { dlg = null; $('#dlssDlg').hidden = true; }
function renderDlg() {
  const g = rtxGen();
  let text = '', body = '', foot = '';
  if (dlg === 'ask') {
    text = '要下载 DLSS 吗？它带来 DLSS 超分和帧生成（RTX 40 为 2 倍，RTX 50 最高 6 倍帧）。文件来自 NVIDIA 官方 GitHub：下载 276 MB，保留 67 MB。不会上传你的任何信息。'
      + (PC?.gpu ? ` Your card: ${esc(PC.gpu)}.` : '');
    foot = '<button class="ghostbtn plain" id="dlssLater">Not now</button><button class="primary lg" id="dlssGo">Download</button>';
  } else if (dlg === 'run') {
    text = esc(SL?.text || '启动中…');
    body = `<div class="progress"><span>${dlssPct()}%</span></div>`;
    foot = '<button class="ghostbtn plain" id="dlssClose">Hide</button>';
  } else if (dlg === 'choose') {
    text = (SL?.text ? `<span class="ok">${esc(SL.text)}</span> ` : '') + (g >= 40 ? 'Frame generation:' : 'DLSS upscaling:');
    body = `<div class="seg" role="radiogroup" aria-label="DLSS">${dlssChoices().map(([v, l]) =>
      `<button data-dfg="${v}" class="${dlssValue() === v ? 'on' : ''}">${l}</button>`).join('')}</div>`;
    foot = '<button class="primary lg" id="dlssDone">Done</button>';
  } else if (dlg === 'error') {
    text = `<span class="bad">${esc(SL?.text || 'The download failed.')}</span>`;
    foot = '<button class="ghostbtn plain" id="dlssClose">Close</button><button class="primary lg" id="dlssGo">Try again</button>';
  }
  $('#dlssText').innerHTML = text;
  $('#dlssBody').innerHTML = body;
  $('#dlssFoot').innerHTML = foot;
}
// ---------------- (Victory) Play before the shaders are prepared for this build ----------------
const play = () => send({ cmd: 'launch.run', id: ID, overrides: st('ov:' + ID, {}), args: '' });
function openWarmDlg() {
  const mins = +(hist().warmMinutes || 0);
  const took = mins >= 1 ? `about ${Math.round(mins)} minutes last time` : mins > 0 ? 'about a minute last time' : '10 to 30 minutes';
  const why = S.shaderState === 'build' ? 'This is a new game build. '
    : S.shaderState === 'flags' ? 'The settings changed since the last warm-up. '
    : S.shaderState === 'failed' ? 'The last warm-up failed. ' : '';
  const many = typeof S.toMake === 'number' ? `${num(S.toMake)} shaders are still to prepare. ` : '';
  $('#warmDlgText').textContent = `${why}${many}The first minutes will stutter and show dark or black areas while the shaders are made during play. Preparing them first takes a while (${took}).`;
  $('#warmNoAsk').checked = false;
  $('#warmDlg').hidden = false;
}
function closeWarmDlg() { $('#warmDlg').hidden = true; }
// an answer: the tick is remembered for this build and these switches (S.warmKeyNow)
function warmDlgDone() {
  if ($('#warmNoAsk').checked && S.warmKeyNow) set({ warmNoAsk: S.warmKeyNow });
  closeWarmDlg();
}

// once: an RTX card, its files not there, not answered before, the welcome steps done, nothing running
function maybeAskDlss() {
  if (dlg || !rtxGen() || dlssReady() || dlssBusy() || st('dlssAsked', false) || !st('setupDone', false)) return;
  if (!$('#welcome').hidden || S.running || job) return;
  openDlg('ask');
}
const SECTIONS = {
  general: () => ['通用', 'Your game and GTA6 CN · Victory.', [
    row((S.gameOk ? '' : bang) + '游戏文件', S.gameOk ? '<span class="ok">game_scarlett_master.exe found</span>' : 'The folder of your own Xbox Series dump', '<button class="mini" data-pick="game">Choose…</button>', pathCode('game')),
    // only for a launcher that isn't inside a release (testing from a build): a normal install never shows this
    ...(S.bundled ? [] : [row(S.filesOk ? '启动器文件' : bang + '<span class="bad">GTA6 CN · Victory files not found</span>',
      'The launcher normally sits in the GTA6 CN · Victory folder. This one doesn’t, so point it at the Victory folder.',
      `<div class="acts"><button class="mini" data-pickdir="neptuneDir">Choose…</button></div>`, pathCode('neptuneDir'))]),
    ...(A.os === 'linux' ? [row('Runner', 'How victory.exe is started on Linux: wine, or a Proton command such as <code>umu-run</code>',
      `<input class="field runner" data-text="wine" value="${esc(st('wine', ''))}" placeholder="wine" spellcheck="false">`)] : []),
    row('Set up again', 'Shows the welcome steps again', '<button class="mini" data-act="welcome">Open</button>'),
  ]],
  graphics: () => ['画面', 'Changes apply the next time you press Play.', [
    row('Mode', 'Fast: Series S, the game’s own resolution and upscaler. Sharp: Series X, slower.',
      `<div class="seg" role="radiogroup" aria-label="Mode"><button data-mode="s" class="${st('seriesX', false) ? '' : 'on'}">Fast</button><button data-mode="x" class="${st('seriesX', false) ? 'on' : ''}">Sharp</button></div>`),
    row('Save video memory', `For graphics cards under 16 GB${PC?.vram ? ` (yours: ${gb(PC.vram)})` : ''}. Warm the shaders again after changing it.`, tog('saver', saverOn(), 'Save video memory')),
    // the title's FidelityFX upscaler needs a PC DLL the player brings (nothing of AMD's ships with Victory)
    row('Upscaler DLL (FidelityFX)', S.dlssOn ? 'Not used while DLSS upscaling is on.'
      : 'A PC <code>amd_fidelityfx_upscaler_dx12.dll</code> of your own: the game’s upscaler runs on it. Without it the game’s upscaler is refused.',
      `<div class="acts"><button class="mini" data-pickfile="fsrDll">Choose…</button>${st('fsrDll', '') ? '<button class="mini ghost" data-clear="fsrDll">Clear</button>' : ''}</div>`,
      pathCode('fsrDll') + (st('fsrDll', '') && S.fsrOk === false ? '<small class="bad">That file is gone.</small>' : '')),
    ...(A.os === 'windows' && PC?.rtx >= 20 ? nvidiaRows() : []),
  ]],
  performance: () => ['性能', 'What happens around each run.', [
    row('Extra draw threads', 'Spreads the game’s drawing over more of your CPU (recommended)', tog('thin', st('thin', true), 'Extra draw threads')),
    row('预热线程数', `How many shaders are prepared at once. All ${S.cores || ''} is fastest; half (the default) uses less memory and keeps your PC usable.`,
      `<div class="seg" role="radiogroup" aria-label="Warm-up threads">${[['half', S.warmJobsDefault], ['all', S.cores]].map(([k, n]) => `<button data-jobs="${n}" class="${(st('warmJobs', 0) || S.warmJobsDefault) == n ? 'on' : ''}">${k === 'half' ? 'Half' : 'All'} (${n})</button>`).join('')}</div>`),
    row('立即预热', '第一次预热约 10 分钟；之后第一局不会卡顿或黑块', `<button class="mini" data-act="warm" ${S.running || job ? 'disabled' : ''}>${job ? '预热中…' : '已预热'}</button>`),
  ]],
  // (Victory) keyboard and mouse drive a stand-in pad while no controller is connected
  controls: () => ['Controls', 'Changes apply the next time you press Play.', [
  ]],
  saves: () => ['存档', '所有版本共用同一个存档目录。', [
    row('Save manager', 'Keep spots, load them, share and import saves', '<button class="mini" data-act="saves">Open</button>'),
    row('Open the save folder', 'Where your kept spots are', '<button class="mini" data-act="saveFolder">Open</button>'),
  ]],
  logs: () => ['日志与问题报告', 'Every run writes a log. Send it with a bug report.', [
    row('Logs folder', 'The last run’s full output', '<button class="mini" data-act="logs">Open</button>'),
  ]],
};
function renderSettings(animate) {
  const q = $('#q').value.trim().toLowerCase();
  $$('.sn').forEach((b) => b.classList.toggle('on', !q && b.dataset.sec === section));
  navBadges();
  const main = $('#setMain');
  if (q) {
    const rows = Object.values(SECTIONS).flatMap((f) => f()[2]).filter((r) => r.includes('data-search="') && r.split('data-search="')[1].split('"')[0].includes(q));
    main.innerHTML = `<div><h1>Search</h1><p class="lead">${rows.length} setting${rows.length === 1 ? '' : 's'} for “${esc(q)}”</p></div>`
      + (rows.length ? `<div class="group">${rows.join('')}</div>` : '<div class="empty">Nothing matches.</div>');
  } else {
    const [title, lead, rows] = SECTIONS[section]();
    main.innerHTML = `<div><h1>${title}</h1><p class="lead">${lead}</p></div><div class="group">${rows.join('')}</div>`
      + (section === 'graphics' ? '<div class="hintbox"><b>Presets are coming.</b> The team is deciding which switch sets players get; the mode and memory saver above already use the team’s tuned set.</div>' : '');
  }
  if (animate) { main.classList.remove('swap'); void main.offsetWidth; main.classList.add('swap'); }
}

// ---------------- first run ----------------
function welcome(open) {
  const w = $('#welcome');
  if (open) {
    step = 0; renderWelcome();
    w.hidden = false; w.classList.add('enter'); w.classList.remove('leaving');
    requestAnimationFrame(() => requestAnimationFrame(() => w.classList.remove('enter')));
    send({ cmd: 'launch.pcinfo' });
  } else {
    w.classList.add('leaving');
    $('#shell').classList.remove('behind');
    setTimeout(() => { w.hidden = true; w.classList.remove('leaving'); }, 450);
  }
}
const ck = (state, text, small = '') => `<div><span class="ck ${state}">${{ y: '✓', n: '!', x: '✕', i: 'i' }[state]}</span><span>${text}</span>${small ? `<small>${small}</small>` : ''}</div>`;
// a scrollbar only when the card is taller than the window
function fitWelcome() {
  const w = $('#welcome');
  if (!w.hidden) w.classList.toggle('scroll', $('#wcard').offsetHeight + 48 > window.innerHeight);
}
window.addEventListener('resize', fitWelcome);
function renderWelcome() {
  $$('.steps li').forEach((li, i) => { li.classList.toggle('on', i === step); li.classList.toggle('done', i < step); });
  $('#wtrack').style.transform = `translateX(${-100 * step}%)`;
  $$('.wpage').forEach((p, i) => p.classList.toggle('away', i !== step));
  const g = st('game', '');
  $('#w0').innerHTML = `
    <div><label>Game</label><div class="sub">Your own Xbox Series dump: pick its game_scarlett_master.exe</div>
      <div class="pick"><div class="field${g ? '' : ' empty'}">${g ? esc(folder(g)) : 'No folder chosen'}</div><button data-pick="game">Browse…</button></div></div>
    ${S.filesOk ? '' : `<div><label class="bad">GTA6 CN · Victory files not found</label><div class="sub">The launcher normally sits in the GTA6 CN · Victory folder, next to victory.exe. This one doesn’t: point it at the Victory folder.</div>
      <div class="pick"><div class="field empty">No folder chosen</div><button data-pickdir="neptuneDir">Browse…</button></div></div>`}
    <div class="checklist">
      ${S.gameOk ? ck('y', 'Game found: game_scarlett_master.exe') : ck(g ? 'x' : 'i', g ? 'That file isn’t game_scarlett_master.exe' : 'Pick the game’s exe in your dump')}
      ${S.filesOk ? ck('y', 'GTA6 CN · Victory files found') : ck('x', 'GTA6 CN · Victory files missing')}
      ${ck('i', 'Supported version: newer game updates may not work yet')}
    </div>`;
  const vram = PC?.vram || 0;
  $('#w1').innerHTML = !PC ? '<div class="checklist">' + ck('i', 'Looking at your PC…') + '</div>' : `
    <div class="checklist">
      ${ck(PC.gpu ? 'y' : 'i', `Graphics card: ${esc(PC.gpu || 'not found')}`, [PC.driver && 'driver ' + esc(PC.driver), vram && gb(vram)].filter(Boolean).join(' · '))}
      ${vram ? (vram >= 15e9 ? ck('y', 'Video memory: enough for the full setting') : ck('n', 'Video memory under 16 GB: the memory saver is on for you', 'Settings › Graphics')) : ''}
      ${PC.ram ? (PC.ram >= 30e9 ? ck('y', `Memory: ${gb(PC.ram)}`) : ck('n', `Memory: ${gb(PC.ram)}`, 'the game uses about 14 GB: close other apps while playing')) : ''}
      ${PC.disk >= 0 ? (PC.disk >= 10e9 ? ck('y', `Disk: ${gb(PC.disk)} free`) : ck('n', `Disk: only ${gb(PC.disk)} free`, 'the shader cache needs a few GB')) : ''}
      ${ck('i', `Processor: ${PC.cpu} threads`)}
    </div>`;
  const h = hist(), wpw = warmProgress();
  $('#w2').innerHTML = `
    <div><label>Prepare the shaders</label><div class="sub">GTA6 CN · Victory turns the game’s shaders into ones your graphics card understands. Doing it now takes about 10 minutes and uses all of your CPU (fans will spin up); after that, the first run doesn’t stutter or show dark areas. You can also skip it and do it later from the home screen.</div></div>
    <div class="checklist">
      ${job ? ck(wpw.zero ? 'y' : 'i', wpw.zero ? wpw.line : wpw.pct !== null ? `Preparing… ${wpw.pct}%` : '准备中…', wpw.zero ? '' : wpw.pct !== null ? wpw.small : '')
        : S.shaderState === 'warm' ? ck('y', '着色器已就绪', st('warmCount', 0) ? num(st('warmCount', 0)) + ' shaders' : '')
        : S.shaderState === 'empty' ? ck('i', 'Nothing to prepare yet', 'play once so the game lists its shaders, then warm them here')
        : ck('i', 'Not prepared yet')}
    </div>
    ${job ? '<div class="progress"><div class="bar"><i></i></div></div>' : `<div><button class="primary lg" data-act="warm" ${S.gameOk && S.filesOk && S.shaderState !== 'empty' ? '' : 'disabled'}>Prepare now</button></div>`}`;
  fillBars(job ? wpw.pct : null);
  const next = $('#wNext');
  next.textContent = step < 2 ? 'Continue' : 'Start playing';
  next.disabled = step === 0 && !(S.gameOk && S.filesOk);
  requestAnimationFrame(fitWelcome);
}
function finishWelcome() { set({ setupDone: true }); welcome(false); setTimeout(maybeAskDlss, 500); }

// ---------------- clicks ----------------
document.addEventListener('click', (e) => {
  const t = e.target;
  const w = t.closest('[data-win]'); if (w) return send({ cmd: 'win.' + w.dataset.win });
  const v = t.closest('[data-view]'); if (v) { if ($('#settings').classList.contains('open')) closeSettings(); return show(v.dataset.view); }
  if (t.closest('#setupBtn')) return welcome(true);
  if (t.closest('#openSettings')) return openSettings();
  if (t.closest('#closeSettings')) return closeSettings();
  const sn = t.closest('.sn'); if (sn) { section = sn.dataset.sec; $('#q').value = ''; return renderSettings(true); }

  if (t.closest('#playBtn')) {
    if (S.running) return send({ cmd: 'launch.stop' });
    // (Victory) not warm for this build and these switches: ask first, unless told not to for this key
    if (S.shaderState && S.shaderState !== 'warm' && S.shaderState !== 'empty' && !(S.warmKeyNow && st('warmNoAsk', '') === S.warmKeyNow)) return openWarmDlg();
    return play();
  }
  if (t.closest('#warmPrep')) { warmDlgDone(); return send({ cmd: 'launch.warm', id: ID }); }
  if (t.closest('#warmAnyway')) { warmDlgDone(); return play(); }
  if (t.closest('#warmClose')) return closeWarmDlg();
  if (t.closest('#warmBtn')) return job ? send({ cmd: 'launch.cancelJob' }) : send({ cmd: 'launch.warm', id: ID });
  // (Victory) DLSS: Get DLSS opens the dialog; Download fetches all eight of NVIDIA's files
  if (t.closest('#dlssBtn')) return openDlg('ask');
  if (t.closest('#dlssGo')) {
    set({ dlssAsked: true });
    SL = { state: 'progress', text: '启动中…', got: 0, total: 0 };
    openDlg('run'); renderHome();
    return send({ cmd: 'launch.getStreamline', full: true });
  }
  if (t.closest('#dlssLater')) { set({ dlssAsked: true }); return closeDlg(); }
  if (t.closest('#dlssDone') || t.closest('#dlssClose')) return closeDlg();
  const dfg = t.closest('[data-dfg]'); if (dfg) return dlssChoose(dfg.dataset.dfg);

  const pk = t.closest('[data-pick]'); if (pk) return send({ cmd: 'launch.pickGame' });
  const pd = t.closest('[data-pickdir]'); if (pd) return send({ cmd: 'launch.pickFolder', key: pd.dataset.pickdir, title: pd.dataset.title || (pd.dataset.pickdir === 'neptuneDir' ? 'The GTA6 CN · Victory folder' : 'The OptiScaler folder') });
  const fgb = t.closest('[data-fg]'); if (fgb) { set({ framegen: +fgb.dataset.fg }); SL = null; return renderSettings(); }
  const pf = t.closest('[data-pickfile]'); if (pf) return send({ cmd: 'launch.pickFile', key: pf.dataset.pickfile });
  const cl = t.closest('[data-clear]'); if (cl) { set({ [cl.dataset.clear]: '' }); return renderSettings(); }
  const tg = t.closest('[data-tog]');
  if (tg) {
    const k = tg.dataset.tog, on = !tg.classList.contains('on');
    tg.classList.toggle('on', on); tg.setAttribute('aria-checked', on);
    if (k === 'saver') setSaver(on); else set({ [k]: on });
    if (k === 'dlss') { SL = null; renderSettings(); }
    return;
  }
  const jb = t.closest('[data-jobs]'); if (jb) { set({ warmJobs: +jb.dataset.jobs }); return renderSettings(); }
  const md = t.closest('[data-mode]'); if (md) { set({ seriesX: md.dataset.mode === 'x' }); renderSettings(); return renderHome(); }
  const act = t.closest('[data-act]');
  if (act) switch (act.dataset.act) {
    case 'warm': return send({ cmd: 'launch.warm', id: ID });
    case 'getSl': SL = { state: 'progress', text: '启动中…' }; renderSettings(); return send({ cmd: 'launch.getStreamline' });
    case 'logs': return send({ cmd: 'launch.openLogs' });
    case 'saves': closeSettings(); return show('saves');
    case 'saveFolder': return send({ cmd: 'openFolder' });
    case 'welcome': closeSettings(); return welcome(true);
  }
  if (t.closest('#wNext')) { if (step < 2) { step++; return renderWelcome(); } return finishWelcome(); }
  if (t.closest('#wSkip')) return finishWelcome();
  const li = t.closest('.steps li'); if (li && +li.dataset.step < step) { step = +li.dataset.step; return renderWelcome(); }

  // saves
  if (t.closest('#importBtn') || t.closest('#importTile')) { $('#svNote').textContent = 'Pick the zip file(s)…'; return send({ cmd: 'import' }); }
  if (t.closest('#openFolder')) return send({ cmd: 'openFolder' });
  if (t.closest('#chooseSaveFolder')) return send({ cmd: 'chooseSaveFolder' });
  const sv = t.closest('[data-sv]');
  if (sv && !sv.disabled) {
    const { sv: a, kind, name } = sv.dataset;
    if (a === 'load' && armed(sv, 'Replace current?')) { $('#svNote').textContent = 'Loading…'; send({ cmd: 'load', name, kind }); }
    if (a === 'delete' && armed(sv, 'Sure?')) send({ cmd: 'delete', name });
    if (a === 'fresh' && armed(sv, 'Clear the story?')) { $('#svNote').textContent = 'Clearing…'; send({ cmd: 'fresh' }); }
    if (a === 'share') send({ cmd: 'share', name, kind });
  }
});
document.addEventListener('change', (e) => {
  if (e.target.matches('[data-text]')) { set({ [e.target.dataset.text]: e.target.value.trim() }); return; }
  if (e.target.matches('#mode')) { set({ seriesX: e.target.value === 'x' }); renderHome(); }
  if (e.target.matches('#dlssSel')) dlssChoose(e.target.value);
});
$('#q').addEventListener('input', () => renderSettings());
document.addEventListener('keydown', (e) => {
  // (Victory) Esc on the first question counts as Not now, so it does not come back
  if (e.key === 'Escape' && !$('#warmDlg').hidden) { closeWarmDlg(); return; }
  if (e.key === 'Escape' && dlg) { if (dlg === 'ask') set({ dlssAsked: true }); closeDlg(); return; }
  if (e.key === 'Escape' && $('#settings').classList.contains('open')) closeSettings();
});
$('#svForm').addEventListener('submit', (e) => {
  e.preventDefault();
  const n = $('#svName').value.trim();
  if (!n) { $('#svNote').textContent = 'Give the save a name first.'; return; }
  send({ cmd: 'snap', name: n });
  $('#svName').value = '';
});

// ---------------- messages from the host ----------------
let booted = false;
window.vismReceive = (m) => {
  switch (m?.type) {
    case 'app':
      A = m;
      REL = m.release || {};
      renderRelease();
      document.title = m.title;
      $('#winBtns').hidden = !m.frame;
      document.body.classList.toggle('framed', !!m.frame);
      $('#testTag').hidden = !m.test;
      break;
    case 'settings': {
      const was = !!S.running;
      S = m;
      if (!booted) {
        booted = true;
        requestAnimationFrame(() => document.body.classList.remove('booting'));
        if (!st('setupDone', false)) welcome(true);
      }
      if (was && !S.running) send({ cmd: 'list' });
      renderHome();
      if ($('#settings').classList.contains('open') && !$('#setMain').contains(document.activeElement)) renderSettings();
      if (!$('#welcome').hidden) renderWelcome();
      maybeAskDlss();
      break;
    }
    case 'pc':
      PC = m;
      // first time on a card under 16 GB: the memory saver comes on by itself
      if (m.vram && m.vram < 15e9 && !st('saverAsked', false)) { set({ saverAsked: true }); setSaver(true); }
      renderHome();
      if (!$('#welcome').hidden) renderWelcome();
      maybeAskDlss();
      break;
    case 'job':
      if (m.state === 'start') { job = m.label; warm = freshWarm(); }
      else job = null;
      renderHome();
      if (!$('#welcome').hidden) renderWelcome();
      break;
    case 'out': {
      // (Victory) the warm-up's lines (apps/victory/src/warm.rs): its first line
      // "<known> pipelines known, <n> made before (<fingerprint>), <n> bad; <to make> to make, <n> processes",
      // progress "<made> of <to make>, <seconds> s" (every two seconds), and "<made> made in <seconds> s (...)"
      if (!job) break;
      let changed = false;
      const head = /(\d+) pipelines known, (\d+) made before \([^)]*\), (\d+) bad; (\d+) to make, (\d+) processes/.exec(m.text);
      if (head) { warm.total = +head[4]; changed = true; }
      for (const p of m.text.matchAll(/^\s*(\d+) of (\d+), (\d+) s\s*$/gm)) {
        warm.count = +p[1]; warm.total = +p[2]; warm.secs = +p[3];
        warm.samples.push({ t: warm.secs, c: warm.count });
        if (warm.samples.length > 200) warm.samples.shift();
        changed = true;
      }
      const sum = /^\s*(\d+) made in (\d+) s \(/m.exec(m.text);
      if (sum) { warm.count = +sum[1]; set({ warmCount: +sum[1] }); changed = true; }
      if (changed) { renderHome(); if (!$('#welcome').hidden) renderWelcome(); }
      break;
    }
    case 'saves': renderSaves(m); break;
    case 'sl':
      SL = m;
      if (dlg === 'run' && m.state !== 'progress') dlg = m.state === 'done' ? 'choose' : 'error';
      if (dlg) renderDlg();
      renderHome();
      if ($('#settings').classList.contains('open')) renderSettings();
      break;
  }
};
window.chrome?.webview?.addEventListener('message', (e) => window.vismReceive(e.data));
send({ cmd: 'init' });
send({ cmd: 'list' });
send({ cmd: 'launch.pcinfo' });
// free memory changes; the game may autosave. Neither is asked for while the game or the warm-up runs.
setInterval(() => { if (!document.hidden && !S.running && !job) { send({ cmd: 'launch.pcinfo' }); if (view === 'saves') send({ cmd: 'list' }); } }, 15000);
