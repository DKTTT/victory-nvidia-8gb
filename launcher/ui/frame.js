// The window's own title bar, on Windows and on Linux (both pages load this after their own script).
// The buttons are drawn here as Windows 11's are: thin line icons, 46 px wide, red close.
// On Windows the header's `app-region: drag` does dragging, snapping and double-click to maximize.
// GTK has no such regions, so on Linux a press on the header asks the window manager to move the
// window (or resize it, from the edges) while the button is still held, the way Linux apps with
// their own title bars do it.
(() => {
  const ICON = {
    min: '<path d="M0 5.5h10"/>',
    max: '<rect x=".5" y=".5" width="9" height="9"/>',
    restore: '<path d="M2.5 2.5v-2h7v7h-2"/><rect x=".5" y="2.5" width="7" height="7"/>',
    close: '<path d="M.5.5l9 9M9.5.5l-9 9"/>',
  };
  const svg = (k) => `<svg width="10" height="10" viewBox="0 0 10 10" fill="none" stroke="currentColor" stroke-width="1" aria-hidden="true">${ICON[k]}</svg>`;
  let os = 'windows', framed = false, max = false;
  const btns = document.getElementById('winBtns');
  function paint() {
    document.body.classList.toggle('maxed', max);
    if (!btns) return;
    btns.querySelector('[data-win="min"]').innerHTML = svg('min');
    const m = btns.querySelector('[data-win="max"]');
    m.innerHTML = svg(max ? 'restore' : 'max');
    m.title = max ? 'Restore' : 'Maximize';
    m.setAttribute('aria-label', m.title);
    btns.querySelector('[data-win="close"]').innerHTML = svg('close');
  }
  paint();

  // ---- Linux: moving, maximizing and resizing ----
  const linux = () => framed && os === 'linux';
  const DRAG = '.drag, .rail, .top, .welcome';
  const NOT = 'button, input, select, textarea, a, label, .status, .jobpill, .winbtns, .wcard, .chip, .pill';
  // the eight resize handles: GDK's edges, NW 0, N 1, NE 2, W 3, E 4, SW 5, S 6, SE 7
  for (const [edge, name] of [[0, 'nw'], [1, 'n'], [2, 'ne'], [3, 'w'], [4, 'e'], [5, 'sw'], [6, 's'], [7, 'se']]) {
    const d = document.createElement('div');
    d.className = 'rz rz-' + name;
    d.dataset.rz = edge;
    document.body.appendChild(d);
  }
  document.addEventListener('mousedown', (e) => {
    if (!linux() || e.button !== 0) return;
    const rz = e.target.closest('[data-rz]');
    if (rz) { e.preventDefault(); send({ cmd: 'win.resize:' + rz.dataset.rz }); return; }
    // a press on the title area: the move starts once the pointer actually moves, so a double-click
    // still reaches the page (a move begun at once hands the second click to the window manager)
    if (e.target.closest(DRAG) && !e.target.closest(NOT)) { e.preventDefault(); armed = { x: e.screenX, y: e.screenY }; }
  });
  let armed = null;
  document.addEventListener('mousemove', (e) => {
    if (!armed) return;
    if (!(e.buttons & 1)) { armed = null; return; }
    if (Math.abs(e.screenX - armed.x) + Math.abs(e.screenY - armed.y) < 4) return;
    armed = null;
    send({ cmd: 'win.drag' });
  });
  document.addEventListener('mouseup', () => { armed = null; });
  document.addEventListener('dblclick', (e) => {
    if (linux() && e.target.closest(DRAG) && !e.target.closest(NOT)) send({ cmd: 'win.max' });
  });

  // the page's own handler sees every message too
  const page = window.vismReceive;
  window.vismReceive = (m) => {
    if (m?.type === 'app') { os = m.os; framed = !!m.frame; document.body.classList.toggle('linuxframe', linux()); }
    if (m?.type === 'win') { max = !!m.max; paint(); }
    page?.(m);
  };
})();
