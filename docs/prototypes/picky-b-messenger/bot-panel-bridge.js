'use strict';
(function () {
  const BOT_IDS = new Set(['picky', 'luna', 'mint', 'moka']);
  const VIEWS = new Set(['home', 'settings', 'routine', 'computer']);
  const PROVIDERS = new Set(['isolated-linux', 'browser', 'host-mac']);
  const TRIGGER_KINDS = new Set(['weekly', 'daily', 'event']);
  const TIMEZONES = new Set(['Asia/Seoul', 'UTC']);
  const ACTIONS = new Set([
    'home', 'settings', 'computer', 'close', 'discard', 'routine.new',
    'routine.open', 'profile.save', 'routine.save', 'routine.test',
    'routine.delete', 'computer.save'
  ]);
  const MAX = { token: 128, text: 4000, id: 96, routines: 32, triggers: 4, history: 30 };
  const expectedView = { 'bot-overview.html': 'home', 'bot-settings.html': 'settings', 'routine-editor.html': 'routine', 'computer-settings.html': 'computer' }[location.pathname.split('/').at(-1)];
  let current = null;
  let renderer = null;

  function text(value, max = MAX.text, empty = true) {
    return typeof value === 'string' && value.length <= max && (empty || value.length > 0);
  }

  function targetOrigin() {
    return location.protocol === 'file:' ? '*' : location.origin;
  }

  function validTrigger(trigger, draft = false) {
    if (!trigger || !TRIGGER_KINDS.has(trigger.kind)) return false;
    if (!text(trigger.time, 5) || (!draft && trigger.kind !== 'event' && !/^(?:[01]\d|2[0-3]):[0-5]\d$/.test(trigger.time))) return false;
    if (!TIMEZONES.has(trigger.timezone)) return false;
    if (!Number.isInteger(trigger.weekday) || trigger.weekday < 0 || trigger.weekday > 6) return false;
    return text(trigger.repository, 160);
  }

  function validRoutine(routine) {
    if (!routine || !text(routine.id, MAX.id, false) || !text(routine.name, 100, false) || !text(routine.prompt, MAX.text, false)) return false;
    if (typeof routine.enabled !== 'boolean' || !Array.isArray(routine.triggers) || routine.triggers.length > MAX.triggers) return false;
    if (!routine.triggers.every(trigger => validTrigger(trigger)) || !Array.isArray(routine.history) || routine.history.length > MAX.history) return false;
    return routine.history.every(item => item && text(item.id, MAX.id, false) && text(item.at, 64, false) && item.status === 'preview' && text(item.summary, 600));
  }

  function validDraft(draft, view) {
    if (draft === null || draft === undefined) return true;
    if (!draft || typeof draft !== 'object' || Array.isArray(draft)) return false;
    if (view === 'settings') return text(draft.name, 60) && text(draft.label, 80) && text(draft.description, 2000) && typeof draft.notifications === 'boolean';
    if (view === 'routine') return text(draft.name, 100) && text(draft.prompt, MAX.text) && typeof draft.enabled === 'boolean' && Array.isArray(draft.triggers) && draft.triggers.length <= MAX.triggers && draft.triggers.every(trigger => validTrigger(trigger, true));
    if (view === 'computer') return PROVIDERS.has(draft.provider);
    return false;
  }

  function validContext(data) {
    if (!data || data.type !== 'bot-panel.init' || !text(data.token, MAX.token, false) || !BOT_IDS.has(data.botId) || !VIEWS.has(data.view) || data.view !== expectedView) return null;
    const profile = data.profile;
    const computer = data.computer;
    if (!profile || !text(profile.name, 60, false) || !text(profile.label, 80) || !text(profile.description, 2000) || typeof profile.notifications !== 'boolean') return null;
    if (!computer || !PROVIDERS.has(computer.provider) || !Array.isArray(data.routines) || data.routines.length > MAX.routines || !data.routines.every(validRoutine)) return null;
    if (data.routine !== null && !validRoutine(data.routine)) return null;
    if (!validDraft(data.draft, data.view)) return null;
    return data;
  }

  function parentEvent(event) {
    if (window.parent === window || event.source !== window.parent) return false;
    return location.protocol === 'file:' ? event.origin === 'null' : event.origin === location.origin;
  }

  function post(message) {
    if (current && window.parent !== window) window.parent.postMessage({ ...message, token: current.token }, targetOrigin());
  }

  function receive(event) {
    if (!parentEvent(event)) return;
    const data = event.data;
    if (!data || typeof data !== 'object') return;
    try { if (JSON.stringify(data).length > 150000) return; } catch { return; }
    if (data.type === 'bot-panel.init') {
      const next = validContext(data);
      if (!next || !renderer) return;
      current = next;
      renderer(next);
      post({ type: 'bot-panel.ready' });
      return;
    }
    if (!current || data.token !== current.token) return;
    if (data.type === 'bot-panel.focus') {
      const heading = document.querySelector('[data-panel-heading]');
      if (heading) heading.focus();
    }
    if (data.type === 'bot-panel.error') {
      const alert = document.getElementById('panel-error');
      if (alert) alert.textContent = text(data.message, 300, false) ? data.message : '저장할 수 없어요. 다시 확인해 주세요.';
    }
  }

  window.BotPanel = {
    register(render) {
      renderer = render;
      window.addEventListener('message', receive);
    },
    preview(context) {
      if (window.parent !== window || !renderer) return;
      const next = validContext(context);
      if (!next) return;
      current = next;
      renderer(next);
    },
    context() { return current; },
    action(action, payload = {}) {
      if (!current || !ACTIONS.has(action) || !payload || typeof payload !== 'object' || Array.isArray(payload)) return;
      post({ type: 'bot-panel.action', action, payload });
    },
    draft(payload) {
      if (!current || !payload || typeof payload !== 'object' || Array.isArray(payload)) return;
      post({ type: 'bot-panel.draft', payload });
    },
    clearError() {
      const alert = document.getElementById('panel-error');
      if (alert) alert.textContent = '';
    }
  };
}());
