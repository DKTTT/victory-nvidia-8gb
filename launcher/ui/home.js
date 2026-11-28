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
  if (m < 1) return '刚刚';
  if (m < 60) return Math.round(m) + ' 分钟前';
  if (m < 48 * 60) return Math.round(m / 60) + ' 小时前';
  return Math.round(m / 1440) + ' 天前';
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
  const of = `${num(w.count)} / ${num(w.total)}`;
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
  if (secs < 60) return '不到 1 分钟';
  const m = Math.round(secs / 60);
  if (m < 60) return `约 ${m} 分钟`;
  const h = Math.floor(m / 60), r = m % 60;
  return `约 ${h} 小时${r ? ' ' + r + ' 分钟' : ''}`;
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
  if (running) eye.textContent = '游戏运行中';
  else if (job) eye.textContent = '正在准备着色器';
  else if (!gameOk || !filesOk) eye.textContent = '';   // the bottom-right corner says it, with the Set up button
  else eye.textContent = '准备就绪';
  $('#hero').classList.toggle('playing', running);
  $('#heroSub').textContent = gameOk && filesOk ? `你的游戏 · ${folder(st('game', ''))}` : '';

  const play = $('#playBtn');
  play.classList.toggle('stop', running);
  play.querySelector('span').textContent = running ? '停止' : '开始游戏';
  play.querySelector('svg').innerHTML = running ? '<rect x="6" y="6" width="12" height="12" rx="2"/>' : '<path d="M7 4l13 8-13 8z"/>';
  play.disabled = !running && (!gameOk || !filesOk || !!job);
  $('#mode').value = st('seriesX', false) ? 'x' : 's';
  $('#mode').disabled = running;
  const warmBtn = $('#warmBtn');
  warmBtn.textContent = job ? '取消' : '预热着色器';
  // (Victory) 点它总是先打开档位选择；只有还没选好游戏文件时才不能点
  warmBtn.disabled = running || (!job && (!gameOk || !filesOk));
  warmBtn.title = !gameOk || !filesOk ? '请先在设置里选择游戏文件' : '';
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
  if (last) c('#cSession', last.minutes < 1 ? '不到 1 分钟' : `${last.minutes} 分钟`,
    `${ago(last.start)} · ${last.stopped ? '已手动停止' : last.code === 0 ? '未崩溃' : '崩溃（' + crash(last.code) + '）'}`, last.stopped || last.code === 0 ? '' : 'warn');
  else c('#cSession', '还没有', '点开始游戏');
  // (Victory) the host judges the warm-up against this game build and the translator's switches
  // and, when it could ask (victory.exe warm --count), by how many are still to make: under 1,000 is warm
  const ss = S.shaderState, n = typeof S.toMake === 'number' ? S.toMake : null;
  const warmSub = () => (h.warmAt ? (st('warmCount', 0) ? `${num(st('warmCount', 0))} 个着色器就绪 · ${ago(h.warmAt)}` : `已就绪 · ${ago(h.warmAt)}`) : '无需再准备什么')
    + (n > 0 ? ` · 还有 ${num(n)} 个小项会在游玩时生成` : '');
  const toDo = n !== null ? `有 ${num(n)} 个着色器待准备` : '';
  if (job) c('#cShaders', wp.value, wp.small, 'ok');
  // a new PC: the game lists its shaders the first time it runs, so there is nothing to warm before that
  else if (ss === 'empty') c('#cShaders', '未预热', '先玩一次，让游戏列出着色器，再在这里预热');
  else if (ss === 'warm' && n !== null) c('#cShaders', '已预热', warmSub(), 'ok');
  else if (!h.warmAt) c('#cShaders', '未预热', toDo ? `${toDo}：预热一次，首局更顺` : '预热一次，首局更顺');
  else if (h.warmCode !== 0) c('#cShaders', '预热失败', '请重试预热着色器', 'bad');
  else if (ss === 'build') c('#cShaders', '需要重新预热', toDo ? `游戏版本已更新 · ${toDo}` : '游戏版本已更新：请重新预热', 'warn');
  else if (ss === 'flags') c('#cShaders', '需要重新预热', toDo ? `设置已更改 · ${toDo}` : '设置已更改：请重新预热', 'warn');
  else if (ss === 'out') c('#cShaders', '需要重新预热', toDo || '请重新预热', 'warn');
  else c('#cShaders', '已预热', warmSub(), 'ok');
  if (PC) c('#cPc', PC.gpu || '显卡', [PC.driver && '驱动 ' + PC.driver, PC.vram && gb(PC.vram)].filter(Boolean).join(' · ') || '详细信息不可用');

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
    if (PC.gpu && /Intel|UHD|Iris|Vega|Basic Render/i.test(PC.gpu)) L.push(['显卡', [`${PC.gpu} · 可能是核显`, 'bad']]);
  if (PC.vram) L.push(['显存', PC.vram >= 15e9 ? [gb(PC.vram), 'ok'] : [`${gb(PC.vram)} · ${saverOn() ? '省显存开' : '建议开省显存'}`, saverOn() ? 'ok' : 'warn']]);
    if (PC.ram) L.push(['可用内存', PC.ramFree >= 16e9 ? [`${gb(PC.ramFree)} 可用`, 'ok'] : [`需要 16 GB · ${gb(PC.ramFree)} 可用`, 'warn']]);
    if (PC.disk >= 0) L.push(['磁盘空间', PC.disk >= 10e9 ? ['充足', 'ok'] : [`${gb(PC.disk)} 可用`, 'warn']]);
  }
  return L;
}
function renderChecks() {
  $('#checks').innerHTML = checksList().map(([k, [v, cls]]) => `<div><span>${esc(k)}</span><span class="${cls}">${esc(v)}</span></div>`).join('');
}

function renderSaveTiles() {
  const box = $('#saveTiles');
  if (!SV) { box.innerHTML = ''; return; }
  const mine = SV.spots.filter((s) => !s.auto).slice(0, 2).map((s, i) => ({ ...s, label: i === 0 ? `最新 · ${ago(s.kept)}` : ago(s.kept) }));
  const team = SV.team.slice(0, 3 - mine.length).map((s) => ({ ...s, label: '团队存档' }));
  box.innerHTML = [...mine, ...team].map((s, i) => `<button class="st${i === 0 && mine.length ? ' cur' : ''}" data-view="saves"><b>${esc(s.name)}</b><div>${esc(s.label)}</div></button>`).join('')
    + '<button class="st add" id="importTile">+ 导入存档</button>';
}

// ---------------- this release ----------------
const verText = () => REL.version ? 'v' + REL.version : REL.commit ? '构建 ' + REL.commit : '';
function renderRelease() {
  $('#heroVer').textContent = verText();
  // the version is always on the home screen: a release's number, a team build's commit, or "dev build"
  $('#verPill').textContent = REL.version ? verText() + ' · 正式版' : verText() || '开发版';
}

// ---------------- saves page (the save manager) ----------------
function renderSaves(m) {
  SV = m;
  $('#chooseSaveFolder').hidden = !m.canChooseSaveFolder;
  // (Victory) the save root (dataDir, the folder holding 7952987A) and the saves folder the game uses
  const rootLine = m.dataDir ? `<b>存档根目录：</b><code>${esc(m.dataDir)}</code>` : '';
  const dirLine = m.saveDirectory ? `<b>游戏存档：</b><code>${esc(m.saveDirectory)}</code>` : '';
  $('#savePath').innerHTML = rootLine || dirLine ? [rootLine, dirLine].filter(Boolean).join('<br>')
    : '还没有找到存档位置：点上面的「自动查找本地存档」，或先玩一次游戏生成存档。';
  $('#svNow').innerHTML = m.found
    ? `<div class="sv-row"><div><b>当前游戏存档</b><span>最后写入 ${esc(m.newest)} · ${fmtSize(m.size)}</span></div>
        ${m.running ? '<span class="warn">游戏正在运行：关闭后才能载入</span>' : ''}
        <button class="mini ghost" data-sv="share" data-kind="current">分享</button></div>`
    : '<div class="sv-row"><div><b>还没有存档</b><span>先玩到游戏自动保存，或在下方载入一个存档点。</span></div></div>';
  $('#svNote').textContent = m.note || '';
  $('#svNote').classList.toggle('bad', m.ok === false);
  $$('[data-sv="fresh"]').forEach((x) => { x.disabled = !!m.running; });
  const row = (s, kind) => `<li class="sv-item${s.auto ? ' auto' : ''}${kind === 'team' ? ' team' : ''}">
      <div class="sv-nm"><b>${esc(s.name)}</b><span>${s.note ? esc(s.note) + ' · ' : ''}游戏内保存 ${esc(s.gameTime)} · ${fmtSize(s.size)}</span></div>
      <div class="acts">
        <button class="mini" data-sv="load" data-kind="${kind}" data-name="${esc(s.name)}" ${m.running ? 'disabled title="请先关闭游戏"' : ''}>载入</button>
        <button class="mini ghost" data-sv="share" data-kind="${kind}" data-name="${esc(s.name)}">分享</button>
        ${kind === 'spot' ? `<button class="mini ghost" data-sv="delete" data-name="${esc(s.name)}">删除</button>` : ''}
      </div></li>`;
  const mine = m.spots.filter((s) => !s.auto), autos = m.spots.filter((s) => s.auto);
  $('#svList').innerHTML =
    (m.team.length ? `<div class="ogroup">团队存档</div><ul class="sv-list">${m.team.map((s) => row(s, 'team')).join('')}</ul>` : '')
    + '<div class="ogroup">你的存档点与导入</div>'
    + (mine.length ? `<ul class="sv-list">${mine.map((s) => row(s, 'spot')).join('')}</ul>` : '<p class="sub">还没有。请在上方为当前存档命名，或导入一个。</p>')
    + (autos.length ? `<div class="ogroup">自动备份（每次载入前，保留最近 5 个）</div><ul class="sv-list">${autos.map((s) => row(s, 'spot')).join('')}</ul>` : '');
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
const bang = '<span class="bang" title="需要注意" aria-label="需要注意">!</span>';
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
  const opts = [[0, '关闭'], [1, '2x'], [2, '3x'], [3, '4x'], [5, '6x']];
  const seg = `<div class="seg" role="radiogroup" aria-label="帧生成">${opts.map(([n, l]) =>
    `<button data-fg="${n}" class="${fg === n ? 'on' : ''}" ${n > 0 && (gen < 40 || (n > 1 && gen < 50)) ? 'disabled' : ''}>${l}</button>`).join('')}</div>`;
  const busy = !!sl.busy || SL?.state === 'progress';
  const wanted = fg > 0 || dlss;
  const ready = (fg === 0 || sl.frameOk) && (!dlss || sl.dlssOk);
  const status = SL ? `<small class="${SL.state === 'done' ? 'ok' : SL.state === 'error' ? 'bad' : ''}">${esc(SL.text)}</small>`
    : !wanted ? ''
    : ready ? `<small class="ok">NVIDIA 签名文件已就绪，位于 ${esc(sl.dir)}</small>`
    : `<small class="warn">尚未就绪：就绪前开始游戏将不启用 DLSS。</small>`;
  return [
    row('帧生成（DLSS）', gen >= 50 ? `DLSS 在游戏两帧之间生成的帧数（${esc(PC.gpu)}：最高 6 倍）`
      : gen >= 40 ? `DLSS 在游戏两帧之间生成的帧数（${esc(PC.gpu)}：2 倍；更高需要 RTX 50）` : `需要 RTX 40 或 50 显卡（你的显卡：${esc(PC.gpu)}）`, seg),
    row('DLSS 超分辨率', 'DLSS 将接管游戏自带的超分；此时上面的 FidelityFX DLL 不再使用', tog('dlss', dlss, 'DLSS 超分辨率')),
    row('获取 NVIDIA 文件', '从 NVIDIA 的 GitHub 下载 Streamline SDK（276 MB），在 <code>%LOCALAPPDATA%\\Victory\\streamline</code> 中只保留 10–67 MB；只有经 NVIDIA 签名的 DLL 才会保留。仅在你按下按钮时进行。',
      `<button class="mini" data-act="getSl" ${busy || S.running ? 'disabled' : ''}>${busy ? '处理中…' : ready && wanted ? '重新检查' : '获取 NVIDIA 文件'}</button>`, status),
    row('或使用你自己的文件夹', '已包含 NVIDIA Streamline DLL 的文件夹（sl.interposer.dll 等）；每个文件都必须由 NVIDIA 签名',
      `<div class="acts"><button class="mini" data-pickdir="streamlineDir" data-title="包含 NVIDIA Streamline DLL 的文件夹">选择…</button>${st('streamlineDir', '') ? '<button class="mini ghost" data-clear="streamlineDir">清除</button>' : ''}</div>`,
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
  if (g < 40) return [['off', '关闭'], ['up', '超分辨率']];
  return [[0, '关闭'], [1, '2x'], ...(g >= 50 ? [[2, '3x'], [3, '4x'], [5, '6x']] : [])].map(([n, l]) => [String(n), l]);
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
  btn.textContent = busy ? `DLSS ${dlssPct()}%` : '获取 DLSS';
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
      + (PC?.gpu ? ` 你的显卡：${esc(PC.gpu)}。` : '');
    foot = '<button class="ghostbtn plain" id="dlssLater">暂不</button><button class="primary lg" id="dlssGo">下载</button>';
  } else if (dlg === 'run') {
    text = esc(SL?.text || '启动中…');
    body = `<div class="progress"><span>${dlssPct()}%</span></div>`;
    foot = '<button class="ghostbtn plain" id="dlssClose">隐藏</button>';
  } else if (dlg === 'choose') {
    text = (SL?.text ? `<span class="ok">${esc(SL.text)}</span> ` : '') + (g >= 40 ? '帧生成：' : 'DLSS 超分辨率：');
    body = `<div class="seg" role="radiogroup" aria-label="DLSS">${dlssChoices().map(([v, l]) =>
      `<button data-dfg="${v}" class="${dlssValue() === v ? 'on' : ''}">${l}</button>`).join('')}</div>`;
    foot = '<button class="primary lg" id="dlssDone">完成</button>';
  } else if (dlg === 'error') {
    text = `<span class="bad">${esc(SL?.text || '下载失败。')}</span>`;
    foot = '<button class="ghostbtn plain" id="dlssClose">关闭</button><button class="primary lg" id="dlssGo">重试</button>';
  }
  $('#dlssText').innerHTML = text;
  $('#dlssBody').innerHTML = body;
  $('#dlssFoot').innerHTML = foot;
}
// ---------------- (Victory) Play before the shaders are prepared for this build ----------------
const play = () => send({ cmd: 'launch.run', id: ID, overrides: st('ov:' + ID, {}), args: '' });
function openWarmDlg() {
  const mins = +(hist().warmMinutes || 0);
  const took = mins >= 1 ? `上次约 ${Math.round(mins)} 分钟` : mins > 0 ? '上次约 1 分钟' : '10 到 30 分钟';
  const why = S.shaderState === 'build' ? '这是新的游戏版本。'
    : S.shaderState === 'flags' ? '自上次预热后设置已更改。'
    : S.shaderState === 'failed' ? '上次预热失败。' : '';
  const many = typeof S.toMake === 'number' ? `还有 ${num(S.toMake)} 个着色器待准备。` : '';
  $('#warmDlgText').textContent = `${why}${many}游玩时如果边玩边生成着色器，最初几分钟会卡顿，并出现暗区或黑块。先预热需要一些时间（${took}）。`;
  $('#warmNoAsk').checked = false;
  $('#warmDlg').hidden = false;
}
function closeWarmDlg() { $('#warmDlg').hidden = true; }
// an answer: the tick is remembered for this build and these switches (S.warmKeyNow)
function warmDlgDone() {
  if ($('#warmNoAsk').checked && S.warmKeyNow) set({ warmNoAsk: S.warmKeyNow });
  closeWarmDlg();
}

// ---------------- (Victory) 预热档位：火力全开（照 预热-火力全开.ps1），确认后才开始 ----------------
let WT = null;   // 主机算好的档位（进程数已按当前内存下调）
let FG = null;   // 自动查找游戏的结果（ok/path），在设置与欢迎页显示一行提示
function openTierDlg(m) {
  if (!m?.tiers?.length) return;
  WT = m;
  WT.selected = m.tiers.some((t) => t.key === 'balanced') ? 'balanced' : m.tiers[0].key;
  $('#tierDlg').hidden = false;
  renderTierDlg();
}
function closeTierDlg() { $('#tierDlg').hidden = true; }
function renderTierDlg() {
  const m = WT;
  if (!m) return;
  const ram = m.freeGb > 0 ? ` · 可用内存 ${m.freeGb} GB` : '';
  $('#tierIntro').textContent = `你的 CPU：${m.cores} 线程${ram}。档位越高越快，桌面也越卡；预计时间来自上次预热。`;
  $('#tierList').innerHTML = m.tiers.map((t) => `<button class="tier${t.key === m.selected ? ' on' : ''}" data-tier="${esc(t.key)}" role="radio" aria-checked="${t.key === m.selected}">
      <b>${esc(t.name)}${t.alias ? `<em>脚本档位：${esc(t.alias)}</em>` : ''}</b>
      <span>进程数 ${t.jobs} · 优先级 ${esc(t.priorityText)}</span>
      <span class="eta">预计时间：${esc(t.eta)}</span></button>`).join('');
  const note = $('#tierRam');
  note.hidden = !m.ramNote;
  note.textContent = m.ramNote || '';
}
function tierSend() {
  const key = WT?.selected || 'balanced';
  closeTierDlg();
  send({ cmd: 'launch.warmStart', id: ID, tier: key });
}

// once: an RTX card, its files not there, not answered before, the welcome steps done, nothing running
function maybeAskDlss() {
  if (dlg || !rtxGen() || dlssReady() || dlssBusy() || st('dlssAsked', false) || !st('setupDone', false)) return;
  if (!$('#welcome').hidden || S.running || job) return;
  openDlg('ask');
}
const SECTIONS = {
  general: () => ['通用', '你的游戏与 GTA6 CN · Victory。', [
    row((S.gameOk ? '' : bang) + '游戏文件', S.gameOk ? '<span class="ok">已找到 game_scarlett_master.exe</span>' : '你自己 Xbox Series 转储中的文件夹',
      '<div class="acts"><button class="mini" data-find="game">自动查找</button><button class="mini" data-pick="game">选择…</button></div>',
      pathCode('game') + (FG ? `<small class="${FG.ok ? 'ok' : 'bad'}">${FG.ok ? '已自动找到并填好游戏路径。' : '没有自动找到游戏，请手动选择。'}</small>` : '')),
    // only for a launcher that isn't inside a release (testing from a build): a normal install never shows this
    ...(S.bundled ? [] : [row(S.filesOk ? '启动器文件' : bang + '<span class="bad">未找到 GTA6 CN · Victory 文件</span>',
      '启动器通常位于 GTA6 CN · Victory 文件夹中。当前启动器不在该位置，请将其指向 Victory 文件夹。',
      `<div class="acts"><button class="mini" data-pickdir="neptuneDir">选择…</button></div>`, pathCode('neptuneDir'))]),
    ...(A.os === 'linux' ? [row('运行器', '在 Linux 上如何启动 victory.exe：wine，或 Proton 命令（如 <code>umu-run</code>）',
      `<input class="field runner" data-text="wine" value="${esc(st('wine', ''))}" placeholder="wine" spellcheck="false">`)] : []),
    row('重新设置', '再次显示欢迎步骤', '<button class="mini" data-act="welcome">打开</button>'),
    // (Victory) the docs shipped with the release: opened from the package folder or the single exe's payload
    row('教程与说明', '从零开始教程、启动器说明与修改器说明（随发行包提供）',
      '<div class="acts"><button class="mini" data-act="doc" data-key="tutorial">教程</button><button class="mini" data-act="doc" data-key="readme">启动器说明</button><button class="mini" data-act="doc" data-key="trainer">修改器</button></div>'),
      row('键盘和鼠标', '没有连接手柄时，用 WASD+鼠标当手柄玩（C/E=扳机）；关闭则只能用手柄', tog('keyboard', st('keyboard', true), '键盘和鼠标')),
      row('按键提示图标', '把游戏的按手键提示换成键盘图标（从你的游戏文件自动生成，或放 mods\\input_icons_kbm.gfx）', tog('keyIcons', st('keyIcons', true), '按键提示图标')),
      row('重置 F1 菜单设置', '清掉游戏内 F1 菜单保存的旧设置（症状：点开始没反应/黑屏后退出；设置由启动器接管，一般不用动）', '<button class="mini" data-act="resetF1">重置</button>'),
      row('带修改器启动', '进游戏后按 F4 打开单机修改器（SHVI / trainer.asi）；不勾选则正常启动', tog('trainer', st('trainer', false), '带修改器启动')),
  ]],
  graphics: () => ['画面', '更改将在下次开始游戏时生效。', [
    row('模式', '快速：Series S，使用游戏自带分辨率和超分。清晰：Series X，速度较慢。',
      `<div class="seg" role="radiogroup" aria-label="模式"><button data-mode="s" class="${st('seriesX', false) ? '' : 'on'}">快速</button><button data-mode="x" class="${st('seriesX', false) ? 'on' : ''}">清晰</button></div>`),
    row('节省显存', `适用于 16 GB 以下的显卡${PC?.vram ? `（你的显卡：${gb(PC.vram)}）` : ''}。更改后请重新预热着色器。`, tog('saver', saverOn(), '节省显存')),
    // the title's FidelityFX upscaler needs a PC DLL the player brings (nothing of AMD's ships with Victory)
    row('超分 DLL（FidelityFX）', S.dlssOn ? '开启 DLSS 超分时不使用。'
      : '你自己的 PC 版 <code>amd_fidelityfx_upscaler_dx12.dll</code>：游戏自带超分依赖它。没有它，游戏自带超分将无法启用。',
      `<div class="acts"><button class="mini" data-pickfile="fsrDll">选择…</button>${st('fsrDll', '') ? '<button class="mini ghost" data-clear="fsrDll">清除</button>' : ''}</div>`,
      pathCode('fsrDll') + (st('fsrDll', '') && S.fsrOk === false ? '<small class="bad">该文件已不存在。</small>' : '')),
    ...(A.os === 'windows' && PC?.rtx >= 20 ? nvidiaRows() : []),
  ]],
  performance: () => ['性能', '每次运行时的相关设置。', [
    row('额外绘制线程', '把游戏的绘制任务分摊到更多 CPU 核心（推荐）', tog('thin', st('thin', true), '额外绘制线程')),
    row('预热线程数', `同时预热多少个着色器。全部 ${S.cores || ''} 个最快；一半（默认）占用更少内存，电脑仍可正常使用。`,
      `<div class="seg" role="radiogroup" aria-label="预热线程数">${[['half', S.warmJobsDefault], ['all', S.cores]].map(([k, n]) => `<button data-jobs="${n}" class="${(st('warmJobs', 0) || S.warmJobsDefault) == n ? 'on' : ''}">${k === 'half' ? '一半' : '全部'} (${n})</button>`).join('')}</div>`),
    row('立即预热', '第一次预热约 10 分钟；之后第一局不会卡顿或黑块', `<button class="mini" data-act="warm" ${S.running || job ? 'disabled' : ''}>${job ? '预热中…' : '开始预热'}</button>`),
  ]],
  // (Victory) keyboard and mouse drive a stand-in pad while no controller is connected
  controls: () => ['操作', '更改将在下次开始游戏时生效。', [
  ]],
  saves: () => ['存档', '所有版本共用同一个存档目录。', [
    row('存档管理', '保留存档点、载入、分享和导入存档', '<button class="mini" data-act="saves">打开</button>'),
    // (Victory) the data root (dataDir) the launcher and the game use; auto-found when it lives elsewhere
    row('存档目录', '游戏存档所在的数据目录（其中包含 <code>7952987A</code>）。换过电脑、装过旧版或游戏存档在别处时，可以让启动器自动查找。',
      '<div class="acts"><button class="mini" data-find="saves">自动查找本地存档</button></div>', pathCode('dataDir')),
    row('打开存档文件夹', '你保留的存档点所在位置', '<button class="mini" data-act="saveFolder">打开</button>'),
  ]],
  logs: () => ['日志与问题报告', '每次运行都会写入日志。提交问题报告时请一并发送。', [
    row('日志文件夹', '上次运行的完整输出', '<button class="mini" data-act="logs">打开</button>'),
    // (Victory) shipped docs: a single-exe release extracts them into its payload and opens them from there
    row('从零开始教程', '新玩家的完整步骤（随启动器附带）', '<button class="mini" data-act="doc" data-key="tutorial">打开</button>'),
    row('启动器说明', '启动器与文件说明（README-中文.txt）', '<button class="mini" data-act="doc" data-key="readme">打开</button>'),
    row('修改器说明', '内置修改器（F4）的按键与用法', '<button class="mini" data-act="doc" data-key="trainer">打开</button>'),
  ]],
};
function renderSettings(animate) {
  const q = $('#q').value.trim().toLowerCase();
  $$('.sn').forEach((b) => b.classList.toggle('on', !q && b.dataset.sec === section));
  navBadges();
  const main = $('#setMain');
  if (q) {
    const rows = Object.values(SECTIONS).flatMap((f) => f()[2]).filter((r) => r.includes('data-search="') && r.split('data-search="')[1].split('"')[0].includes(q));
    main.innerHTML = `<div><h1>搜索</h1><p class="lead">找到 ${rows.length} 项与“${esc(q)}”相关的设置</p></div>`
      + (rows.length ? `<div class="group">${rows.join('')}</div>` : '<div class="empty">没有匹配项。</div>');
  } else {
    const [title, lead, rows] = SECTIONS[section]();
    main.innerHTML = `<div><h1>${title}</h1><p class="lead">${lead}</p></div><div class="group">${rows.join('')}</div>`
      + (section === 'graphics' ? '<div class="hintbox"><b>预设即将推出。</b>团队正在确定为玩家提供哪些开关组合；上方的模式和显存节省已使用团队调好的设置。</div>' : '');
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
    <div><label>游戏</label><div class="sub">你自己的 Xbox Series 转储：选择其中的 game_scarlett_master.exe，或让启动器自动查找</div>
      <div class="pick"><div class="field${g ? '' : ' empty'}">${g ? esc(folder(g)) : '未选择文件夹'}</div><button data-find="game">自动查找</button><button data-pick="game">浏览…</button></div>
      ${FG ? `<div class="fine ${FG.ok ? 'ok' : 'bad'}">${FG.ok ? '已自动找到并填好游戏路径。' : '没有自动找到游戏，请手动选择。'}</div>` : ''}</div>
    ${S.filesOk ? '' : `<div><label class="bad">未找到 GTA6 CN · Victory 文件</label><div class="sub">启动器通常位于 GTA6 CN · Victory 文件夹中，与 victory.exe 相邻。当前启动器不在该位置：请将其指向 Victory 文件夹。</div>
      <div class="pick"><div class="field empty">未选择文件夹</div><button data-pickdir="neptuneDir">浏览…</button></div></div>`}
    <div class="checklist">
      ${S.gameOk ? ck('y', '已找到游戏：game_scarlett_master.exe') : ck(g ? 'x' : 'i', g ? '该文件不是 game_scarlett_master.exe' : '在你的转储中选择游戏的 exe')}
      ${S.filesOk ? ck('y', '已找到 GTA6 CN · Victory 文件') : ck('x', '缺少 GTA6 CN · Victory 文件')}
      ${ck('i', '支持的版本：更新的游戏更新可能尚不可用')}
    </div>`;
  const vram = PC?.vram || 0;
  $('#w1').innerHTML = !PC ? '<div class="checklist">' + ck('i', '正在检查你的电脑…') + '</div>' : `
    <div class="checklist">
      ${ck(PC.gpu ? 'y' : 'i', `显卡：${esc(PC.gpu || '未找到')}`, [PC.driver && '驱动 ' + esc(PC.driver), vram && gb(vram)].filter(Boolean).join(' · '))}
      ${vram ? (vram >= 15e9 ? ck('y', '显存：足够使用完整设置') : ck('n', '显存低于 16 GB：已为你开启显存节省', '设置 › 画面')) : ''}
      ${PC.ram ? (PC.ram >= 30e9 ? ck('y', `内存：${gb(PC.ram)}`) : ck('n', `内存：${gb(PC.ram)}`, '游戏约占用 14 GB：游玩时请关闭其他应用')) : ''}
      ${PC.disk >= 0 ? (PC.disk >= 10e9 ? ck('y', `磁盘：${gb(PC.disk)} 可用`) : ck('n', `磁盘：仅剩 ${gb(PC.disk)} 可用`, '着色器缓存需要几个 GB')) : ''}
      ${ck('i', `处理器：${PC.cpu} 线程`)}
    </div>`;
  const h = hist(), wpw = warmProgress();
  $('#w2').innerHTML = `
    <div><label>准备着色器</label><div class="sub">GTA6 CN · Victory 会将游戏的着色器转译成你的显卡能理解的版本。现在进行约需 10 分钟，并会占满所有 CPU（风扇会全速运转）；之后首次运行不会卡顿，也不会出现暗区。你也可以跳过，之后在主页进行。</div></div>
    <div class="checklist">
      ${job ? ck(wpw.zero ? 'y' : 'i', wpw.zero ? wpw.line : wpw.pct !== null ? `准备中… ${wpw.pct}%` : '准备中…', wpw.zero ? '' : wpw.pct !== null ? wpw.small : '')
        : S.shaderState === 'warm' ? ck('y', '着色器已就绪', st('warmCount', 0) ? num(st('warmCount', 0)) + ' 个着色器' : '')
        : S.shaderState === 'empty' ? ck('i', '暂无需准备', '先玩一次让游戏列出着色器，再在这里预热')
        : ck('i', '尚未预热')}
    </div>
    ${job ? '<div class="progress"><div class="bar"><i></i></div></div>' : `<div><button class="primary lg" data-act="warm" ${S.gameOk && S.filesOk && S.shaderState !== 'empty' ? '' : 'disabled'}>立即预热</button></div>`}`;
  fillBars(job ? wpw.pct : null);
  const next = $('#wNext');
  next.textContent = step < 2 ? '继续' : '开始游戏';
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
  // (Victory) 档位窗：选中一个再按「继续」才开始；取消什么都不做
  if (t.closest('#tierGo')) return tierSend();
  if (t.closest('#tierCancel')) return closeTierDlg();
  const tr = t.closest('[data-tier]');
  if (tr && WT) { WT.selected = tr.dataset.tier; return renderTierDlg(); }
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
  // (Victory) 自动查找游戏目录 / 本地存档：成功时设置消息会把路径填好，并刷新存档页
  const fd = t.closest('[data-find]');
  if (fd) {
    if (fd.dataset.find !== 'saves') return send({ cmd: 'launch.findGame' });
    const note = $('#svNote');
    if (note) { note.textContent = '正在自动查找本地存档…'; note.classList.remove('bad'); }
    return send({ cmd: 'launch.findSaves' });
  }
  const pd = t.closest('[data-pickdir]'); if (pd) return send({ cmd: 'launch.pickFolder', key: pd.dataset.pickdir, title: pd.dataset.title || (pd.dataset.pickdir === 'neptuneDir' ? 'GTA6 CN · Victory 文件夹' : 'OptiScaler 文件夹') });
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
    case 'doc': return send({ cmd: 'launch.openDoc', key: act.dataset.key });
    case 'saves': closeSettings(); return show('saves');
    case 'saveFolder': return send({ cmd: 'openFolder' });
    case 'welcome': closeSettings(); return welcome(true);
    case 'resetF1': return send({ cmd: 'launch.resetF1' });
  }
  if (t.closest('#wNext')) { if (step < 2) { step++; return renderWelcome(); } return finishWelcome(); }
  if (t.closest('#wSkip')) return finishWelcome();
  const li = t.closest('.steps li'); if (li && +li.dataset.step < step) { step = +li.dataset.step; return renderWelcome(); }

  // saves
  if (t.closest('#importBtn') || t.closest('#importTile')) { $('#svNote').textContent = '选择 zip 文件…'; return send({ cmd: 'import' }); }
  if (t.closest('#openFolder')) return send({ cmd: 'openFolder' });
  if (t.closest('#chooseSaveFolder')) return send({ cmd: 'chooseSaveFolder' });
  const sv = t.closest('[data-sv]');
  if (sv && !sv.disabled) {
    const { sv: a, kind, name } = sv.dataset;
    if (a === 'load' && armed(sv, '替换当前存档？')) { $('#svNote').textContent = '正在载入…'; send({ cmd: 'load', name, kind }); }
    if (a === 'delete' && armed(sv, '确定？')) send({ cmd: 'delete', name });
    if (a === 'fresh' && armed(sv, '清空剧情？')) { $('#svNote').textContent = '正在清除…'; send({ cmd: 'fresh' }); }
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
  // (Victory) 档位窗：Esc 等于取消
  if (e.key === 'Escape' && !$('#tierDlg').hidden) { closeTierDlg(); return; }
  // (Victory) Esc on the first question counts as Not now, so it does not come back
  if (e.key === 'Escape' && !$('#warmDlg').hidden) { closeWarmDlg(); return; }
  if (e.key === 'Escape' && dlg) { if (dlg === 'ask') set({ dlssAsked: true }); closeDlg(); return; }
  if (e.key === 'Escape' && $('#settings').classList.contains('open')) closeSettings();
});
$('#svForm').addEventListener('submit', (e) => {
  e.preventDefault();
  const n = $('#svName').value.trim();
  if (!n) { $('#svNote').textContent = '请先给存档起个名字。'; return; }
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
    // (Victory) 预热档位表，来自主机（数值与 ps1 的「火力全开」一致）
    case 'warmTiers': openTierDlg(m); break;
    // (Victory) 自动查找游戏的结果：设置/欢迎页显示一行提示，成功时设置消息已把路径填好
    case 'findGame':
      FG = m;
      renderHome();
      if (!$('#welcome').hidden) renderWelcome();
      if ($('#settings').classList.contains('open')) renderSettings();
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
