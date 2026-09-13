/* Prototype appearance only. This bridge cannot change native settings, bots or execution. */
window.createMockAppSettings = function ({ frame, dialog, button, initial, apply, notify }) {
  const key = 'picky.mockup.b05.appearance';
  const valid = value => value && ['light', 'dark'].includes(value.theme) && ['comfortable', 'compact'].includes(value.density);
  let values = { theme: 'light', density: 'comfortable' };
  try { const saved = JSON.parse(localStorage.getItem(key)); if (valid(saved)) values = { theme: saved.theme, density: saved.density }; } catch { /* Keep usable in-memory defaults. */ }
  if (['light', 'dark'].includes(initial.theme)) values.theme = initial.theme;
  if (['comfortable', 'compact'].includes(initial.density)) values.density = initial.density;
  let token = null;
  let returnFocus = true;
  const origin = location.protocol === 'file:' ? '*' : location.origin;
  function send(type) { if (token) frame.contentWindow.postMessage({ type, token, ...values }, origin); }
  function change(next) {
    if (!valid(next)) return;
    values = { theme: next.theme, density: next.density };
    try { localStorage.setItem(key, JSON.stringify(values)); } catch { notify('화면 설정은 이 탭에서만 유지됩니다. 브라우저에 저장하지 못했어요.'); }
    apply({ ...values });
    send('app-settings.values');
  }
  function close(focus = true) { returnFocus = focus; token = null; dialog.close(); }
  function open() {
    if (dialog.open) return;
    returnFocus = true;
    token = crypto.randomUUID();
    frame.hidden = true;
    frame.src = 'app-settings.html?panel=' + token + '#theme=' + values.theme;
    dialog.showModal();
  }
  frame.addEventListener('load', () => { if (dialog.open) send('app-settings.init'); });
  dialog.addEventListener('close', () => {
    if (dialog.open) return;
    token = null;
    if (returnFocus) button.focus({ preventScroll: true });
  });
  window.addEventListener('message', event => {
    if (!dialog.open || !token || event.source !== frame.contentWindow || event.origin !== (location.protocol === 'file:' ? 'null' : location.origin)) return;
    const data = event.data;
    if (!data || data.token !== token) return;
    if (data.type === 'app-settings.ready') { frame.hidden = false; send('app-settings.focus'); }
    else if (data.type === 'app-settings.close') close();
    else if (data.type === 'app-settings.change') change(data);
  });
  return { open, close, change, get values() { return { ...values }; } };
};
