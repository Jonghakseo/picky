/* Prototype-local storage and iframe routing only. No Pi, scheduler, Computer or native API calls. */
'use strict';
window.createMockBotManagement = function createMockBotManagement(options) {
  const ids = ['picky', 'luna', 'mint', 'moka'];
  const pages = { home: 'bot-overview.html', settings: 'bot-settings.html', routine: 'routine-editor.html', history: 'routine-history.html', computer: 'computer-settings.html' };
  const providers = ['isolated-linux', 'browser', 'host-mac'];
  const key = 'picky.mockup.b04.bot-management';
  const clone = value => structuredClone(value);
  const text = (value, max, required = false) => typeof value === 'string' && value.length <= max && (!required || value.trim().length > 0);
  const profileValue = (value, draft = false) => value && text(value.name, 60, !draft) && text(value.label, 80) && text(value.description, 2000) && typeof value.notifications === 'boolean'
    ? { name: value.name, label: value.label, description: value.description, notifications: value.notifications } : null;
  function routineValue(value, draft = false) {
    if (!value || !text(value.name, 100, !draft) || !text(value.prompt, 4000, !draft) || typeof value.enabled !== 'boolean' || !Array.isArray(value.triggers) || value.triggers.length > 4 || (!draft && !value.triggers.length)) return null;
    const triggers = [];
    for (const trigger of value.triggers) {
      if (!trigger || !['weekly', 'daily', 'event'].includes(trigger.kind)) return null;
      if (!Number.isInteger(trigger.weekday) || trigger.weekday < 0 || trigger.weekday > 6 || !['Asia/Seoul', 'UTC'].includes(trigger.timezone)) return null;
      if (!text(trigger.time, 5) || (!draft && trigger.kind !== 'event' && !/^(?:[01]\d|2[0-3]):[0-5]\d$/.test(trigger.time))) return null;
      if (!text(trigger.repository, 160) || (!draft && trigger.kind === 'event' && !/^[a-z\d_.-]+\/[a-z\d_.-]+$/i.test(trigger.repository))) return null;
      triggers.push({ kind: trigger.kind, weekday: trigger.weekday, time: trigger.time, timezone: trigger.timezone, repository: trigger.repository });
    }
    return { name: value.name, prompt: value.prompt, enabled: value.enabled, triggers };
  }
  function runValue(run) {
    if (!run || !text(run.id, 80, true) || !text(run.at, 40, true) || !Number.isFinite(Date.parse(run.at)) || run.status !== 'preview' || !text(run.summary, 500)) return null;
    return { id: run.id, at: run.at, status: 'preview', summary: run.summary, definition: routineValue(run.definition) };
  }
  const weekly = () => ({ kind: 'weekly', weekday: 1, time: '09:00', timezone: 'Asia/Seoul', repository: 'example/booking' });
  const initialNames = { picky: '주간 진행 상황 정리', luna: '예약 화면 변경 조사', mint: '회귀 테스트 점검', moka: '수정안 검토 모음' };
  const data = Object.fromEntries(ids.map(id => [id, {
    profile: { name: options.people[id].name, label: options.people[id].role, description: '', notifications: true },
    computer: { provider: 'isolated-linux' },
    routines: [{ id: id + '-weekly', name: initialNames[id], prompt: '예약 날짜 수정 작업의 변경 사항을 확인하고 이 대화에 요약해줘. 배포하거나 외부 메시지를 보내지 마.', enabled: true, triggers: [weekly()], history: [] }],
  }]));
  // Stored display data cannot add bots, sessions, permissions or executable actions.
  try {
    const raw = localStorage.getItem(key);
    if (raw && raw.length <= 8000000) {
      const saved = JSON.parse(raw);
      if (saved?.version === 1) for (const id of ids) {
        const bot = saved.bots?.[id];
        if (!bot) continue;
        data[id].profile = profileValue(bot.profile) || data[id].profile;
        if (providers.includes(bot.computer?.provider)) data[id].computer.provider = bot.computer.provider;
        if (Array.isArray(bot.routines) && bot.routines.length <= 12) {
          const seen = new Set();
          data[id].routines = bot.routines.flatMap(row => {
            const value = routineValue(row);
            if (!value || !text(row.id, 80, true) || seen.has(row.id)) return [];
            seen.add(row.id);
            const history = Array.isArray(row.history) ? row.history.slice(-20).map(runValue).filter(Boolean) : [];
            return [{ id: row.id, ...value, history }];
          });
        }
      }
    }
  } catch { /* Invalid or unavailable browser storage leaves the fictional defaults intact. */ }
  for (const id of ids) options.people[id].name = data[id].profile.name;

  const drafts = new Map();
  const frame = options.frame;
  const container = options.container;
  const origin = location.protocol === 'file:' ? '*' : location.origin;
  let current = null;
  let pendingFocus = false;
  const draftKey = context => [context.botId, context.view, context.routineId || 'new'].join('/');
  const selectedRoutine = () => current?.routineId ? data[current.botId].routines.find(row => row.id === current.routineId) : null;
  function persist() {
    try { localStorage.setItem(key, JSON.stringify({ version: 1, bots: data })); }
    catch { options.notify('브라우저에 저장하지 못했어요. 변경은 이 탭에서만 유지됩니다.'); }
  }
  function send(message) { frame.contentWindow.postMessage({ token: current.token, ...message }, origin); }
  function payload() {
    const bot = data[current.botId];
    // Only the selected routine needs full historical definitions; list entries stay small.
    const routines = bot.routines.map(row => ({ ...clone(row), history: row.history.map(({ definition, ...run }) => run) }));
    return { type: 'bot-panel.init', botId: current.botId, view: current.view, profile: clone(bot.profile), computer: clone(bot.computer), routines, routine: clone(selectedRoutine()), draft: clone(drafts.get(draftKey(current)) || null) };
  }
  function load(view, routineId = null, focus = true) {
    const botId = options.selected();
    if (!ids.includes(botId) || !pages[view]) return;
    current = { botId, view, routineId, token: crypto.randomUUID(), owner: options.owner(), theme: options.theme() };
    pendingFocus = focus;
    frame.hidden = true;
    container.hidden = false;
    frame.title = data[botId].profile.name + ' 피클 관리';
    // A query creates a fresh file document; changing only the hash would not emit load.
    frame.src = pages[view] + '?panel=' + current.token + '#theme=' + current.theme;
  }
  function close(focus = true) {
    current = null;
    pendingFocus = false;
    container.hidden = true;
    frame.hidden = true;
    if (focus) {
      options.render();
      options.button.focus({ preventScroll: true });
    }
  }
  function open(view = 'home') {
    if (!ids.includes(options.selected())) return;
    options.closeRequest();
    load(view);
    options.render();
  }
  function sync() {
    options.button.hidden = !ids.includes(options.selected());
    options.button.setAttribute('aria-label', (options.people[options.selected()]?.name || '') + ' 피클 관리');
    options.button.setAttribute('aria-expanded', String(!!current));
    if (!current) return;
    if (!ids.includes(options.selected())) { close(false); return; }
    if (current.botId !== options.selected() || current.owner !== options.owner()) load('home');
    else if (current.theme !== options.theme()) load(current.view, current.routineId, false);
  }
  frame.addEventListener('load', () => { if (current) send(payload()); });
  window.addEventListener('message', event => {
    if (!current || event.source !== frame.contentWindow || event.origin !== (location.protocol === 'file:' ? 'null' : location.origin)) return;
    const message = event.data;
    try { if (!message || JSON.stringify(message).length > 65536) return; } catch { return; }
    if (message.token !== current.token || current.botId !== options.selected() || current.owner !== options.owner()) return;
    if (message.type === 'bot-panel.ready') {
      frame.hidden = false;
      if (pendingFocus) { send({ type: 'bot-panel.focus' }); pendingFocus = false; }
      return;
    }
    const raw = message.payload;
    if (message.type === 'bot-panel.draft') {
      const draft = current.view === 'settings' ? profileValue(raw, true) : current.view === 'routine' ? routineValue(raw, true) : current.view === 'computer' && providers.includes(raw?.provider) ? { provider: raw.provider } : null;
      if (draft) drafts.set(draftKey(current), clone(draft));
      return;
    }
    if (message.type !== 'bot-panel.action') return;
    const bot = data[current.botId];
    const error = text => send({ type: 'bot-panel.error', message: text });
    const home = () => { load('home'); options.render(); };
    switch (message.action) {
      case 'close': close(); return;
      case 'home': home(); return;
      case 'settings': load('settings'); break;
      case 'computer': load('computer'); break;
      case 'discard': drafts.delete(draftKey(current)); home(); return;
      case 'routine.new':
        if (bot.routines.length >= 12) { error('이 목업에서는 피클마다 루틴을 12개까지 만들 수 있어요.'); return; }
        load('routine'); break;
      case 'routine.open':
        if (!bot.routines.some(row => row.id === raw?.id)) return;
        load('routine', raw.id); break;
      case 'routine.history':
        if (!bot.routines.some(row => row.id === raw?.id)) return;
        load('history', raw.id); break;
      case 'profile.save': {
        if (current.view !== 'settings') return;
        const value = profileValue(raw);
        if (!value) { error('이름과 입력 길이를 확인해 주세요.'); return; }
        bot.profile = { ...value, name: value.name.trim() };
        options.people[current.botId].name = bot.profile.name;
        drafts.delete(draftKey(current));
        persist(); home(); return;
      }
      case 'computer.save':
        if (current.view !== 'computer' || !providers.includes(raw?.provider)) return;
        bot.computer = { provider: raw.provider };
        drafts.delete(draftKey(current));
        persist(); home(); return;
      case 'routine.save': {
        if (current.view !== 'routine') return;
        const value = routineValue(raw);
        if (!value) { error('이름·지침·실행 시기를 확인해 주세요.'); return; }
        const existing = selectedRoutine();
        if (current.routineId && !existing) return;
        if (!existing && bot.routines.length >= 12) { error('루틴은 피클마다 12개까지 만들 수 있어요.'); return; }
        if (existing) Object.assign(existing, value);
        else bot.routines.push({ id: crypto.randomUUID(), ...value, history: [] });
        drafts.delete(draftKey(current));
        persist(); home(); return;
      }
      case 'routine.test': {
        if (current.view !== 'routine') return;
        const routine = selectedRoutine();
        if (!routine) return;
        const draft = drafts.get(draftKey(current));
        if (draft && JSON.stringify(draft) !== JSON.stringify(routineValue(routine))) {
          error('변경 내용을 먼저 저장하거나 취소해 주세요. 테스트는 저장된 루틴을 사용합니다.');
          return;
        }
        // This is a labeled preview receipt, not an accepted or completed Pi execution.
        routine.history.push({ id: crypto.randomUUID(), at: new Date().toISOString(), status: 'preview', summary: '저장된 루틴의 화면 흐름을 확인했습니다. 실제 도구 호출은 없습니다.', definition: clone(routineValue(routine)) });
        routine.history = routine.history.slice(-20);
        persist(); load('routine', routine.id); break;
      }
      case 'routine.delete':
        if (current.view !== 'routine' || !selectedRoutine()) return;
        bot.routines = bot.routines.filter(row => row.id !== current.routineId);
        drafts.delete(draftKey(current));
        persist(); home(); return;
      default: return;
    }
    options.render();
  });
  return {
    open, close, sync,
    isOpen: () => !!current,
    context: () => current ? '피클 관리 / ' + ({ home: '컴퓨터·루틴', settings: '설정', routine: '루틴 편집', history: '루틴 히스토리', computer: '컴퓨터 환경' }[current.view]) : '피클 관리 닫힘',
  };
};
