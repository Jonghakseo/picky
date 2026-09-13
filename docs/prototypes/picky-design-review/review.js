(() => {
  'use strict';

  const noteKey = 'picky.design.ds01.review';
  const draftKey = 'picky.design.ds01.drafts';
  const themeKey = 'picky.design.ds01.theme';
  const knownPages = new Set(['foundations', 'controls', 'patterns']);
  const page = knownPages.has(document.body.dataset.page) ? document.body.dataset.page : 'foundations';
  const $ = selector => document.querySelector(selector);
  let storageHealthy = true;
  let notes = [];
  let drafts = {};
  let dialogTrigger = null;

  const validTheme = value => ['light', 'dark'].includes(value) ? value : 'light';
  const validText = (value, limit) => typeof value === 'string' && value.length <= limit;
  const validDate = value => typeof value === 'string' && Number.isFinite(Date.parse(value));
  const validNote = value => value && knownPages.has(value.page) && validText(value.section, 120) && validText(value.text, 4000) && value.text.trim() && validDate(value.at);
  const validDrafts = value => value && typeof value === 'object' && !Array.isArray(value)
    && Object.entries(value).every(([key, draft]) => knownPages.has(key) && draft && validText(draft.text, 4000) && validText(draft.section, 120));

  function readJSON(key, fallback, validate) {
    try {
      const parsed = JSON.parse(localStorage.getItem(key) || 'null');
      return validate(parsed) ? parsed : fallback;
    } catch {
      storageHealthy = false;
      return fallback;
    }
  }

  function storageMessage() {
    return storageHealthy
      ? '이 브라우저에만 저장합니다. 자동 전송하거나 승인하지 않습니다.'
      : '브라우저 저장을 사용할 수 없어 현재 화면의 임시 상태로만 유지합니다. 이동·새로고침 전에 Markdown으로 내려받아 주세요.';
  }

  function writeJSON(key, value) {
    try { localStorage.setItem(key, JSON.stringify(value)); }
    catch { storageHealthy = false; }
    const warning = $('[data-feedback-storage]');
    if (warning) warning.textContent = storageMessage();
  }

  notes = readJSON(noteKey, [], value => Array.isArray(value) && value.length <= 200 && value.every(validNote));
  drafts = readJSON(draftKey, {}, validDrafts);
  let storedTheme = 'light';
  try { storedTheme = validTheme(localStorage.getItem(themeKey)); }
  catch { storageHealthy = false; }

  function applyTheme(theme) {
    const value = validTheme(theme);
    document.documentElement.dataset.theme = value;
    document.querySelectorAll('[data-theme-select]').forEach(select => { select.value = value; });
  }

  function storeTheme(theme) {
    applyTheme(theme);
    try { localStorage.setItem(themeKey, validTheme(theme)); }
    catch { storageHealthy = false; }
    renderFeedback();
  }

  function renderFeedback() {
    const list = $('[data-feedback-list]');
    const count = $('[data-feedback-count]');
    const warning = $('[data-feedback-storage]');
    const text = $('[data-feedback-text]');
    const scoped = notes.filter(note => note.page === page);
    if (count) count.textContent = scoped.length ? `${scoped.length}개` : '없음';
    if (warning) warning.textContent = storageMessage();
    if (text) text.value = drafts[page]?.text || '';
    const section = $('[data-feedback-section]');
    if (section && [...section.options].some(option => option.value === drafts[page]?.section)) section.value = drafts[page].section;
    if (!list) return;
    list.replaceChildren();
    scoped.forEach(note => {
      const item = document.createElement('div');
      item.className = 'feedback-note';
      item.textContent = note.text;
      const meta = document.createElement('small');
      meta.textContent = `${note.section} · ${new Date(note.at).toLocaleString('ko-KR')}`;
      item.append(meta);
      list.append(item);
    });
  }

  function exportNotes() {
    const labels = { foundations: '기초', controls: '컨트롤', patterns: '메신저 패턴' };
    const lines = [
      '# Picky DS.01 검수 의견',
      '',
      '> 디자인 제안에 대한 의견입니다. 실제 제품 동작, 접근성, 성능 또는 구현 완료를 검증하지 않으며, 어떤 항목도 승인이나 적용을 의미하지 않습니다.',
      '',
      `- 내보낸 시각: ${new Date().toISOString()}`,
      '- 범위: DS.01 기초 · 컨트롤 · 메신저 패턴',
      '',
      '## 의견'
    ];
    if (!notes.length) lines.push('', '_기록한 의견이 없습니다._');
    notes.forEach((note, index) => lines.push('', `### ${index + 1}. ${labels[note.page]} · ${note.section}`, '', note.text, '', `기록: ${note.at}`));
    const link = document.createElement('a');
    link.href = URL.createObjectURL(new Blob([lines.join('\n')], { type: 'text/markdown;charset=utf-8' }));
    link.download = 'picky-design-ds01-feedback.md';
    link.click();
    setTimeout(() => URL.revokeObjectURL(link.href), 0);
  }

  function selectTab(tab) {
    const group = tab.closest('[data-tabs]');
    const tabs = [...group.querySelectorAll('[data-tab]')];
    tabs.forEach(candidate => {
      const selected = candidate === tab;
      candidate.setAttribute('aria-selected', String(selected));
      candidate.tabIndex = selected ? 0 : -1;
    });
    const panels = [...group.parentElement.querySelectorAll('[data-tab-panel]')];
    panels.forEach(panel => { panel.hidden = panel.id !== tab.getAttribute('aria-controls'); });
  }

  function closeMenu(menu, focus = true) {
    menu.hidden = true;
    const trigger = document.querySelector(`[data-menu-button="${menu.id}"]`);
    trigger?.setAttribute('aria-expanded', 'false');
    if (focus) trigger?.focus({ preventScroll: true });
  }

  function openMenu(trigger, menu) {
    document.querySelectorAll('.menu:not([hidden])').forEach(open => closeMenu(open, false));
    menu.hidden = false;
    trigger.setAttribute('aria-expanded', 'true');
    menu.querySelector('[role="menuitem"]')?.focus({ preventScroll: true });
  }

  function specimen(message, target) {
    const result = target || $('[data-specimen-result]');
    if (!result) return;
    result.textContent = message;
    result.hidden = false;
  }

  applyTheme(storedTheme);
  document.querySelectorAll('[data-theme-select]').forEach(select => select.addEventListener('change', () => storeTheme(select.value)));

  const feedbackForm = $('[data-feedback-form]');
  const feedbackText = $('[data-feedback-text]');
  function saveDraft() {
    drafts[page] = { text: feedbackText.value.slice(0, 4000), section: $('[data-feedback-section]').value };
    writeJSON(draftKey, drafts);
  }
  feedbackText?.addEventListener('input', saveDraft);
  $('[data-feedback-section]')?.addEventListener('change', saveDraft);
  feedbackForm?.addEventListener('submit', event => {
    event.preventDefault();
    const section = $('[data-feedback-section]').value;
    const text = feedbackText.value.trim();
    if (!validText(section, 120) || !text) { feedbackText.focus(); return; }
    if (notes.length >= 200) { $('[data-feedback-storage]').textContent = '검수 의견은 200개까지 보관합니다. 추가 의견은 내려받은 Markdown 파일에 이어 적어 주세요.'; return; }
    notes.push({ page, section, text: text.slice(0, 4000), at: new Date().toISOString() });
    drafts[page] = { text: '', section };
    writeJSON(noteKey, notes);
    writeJSON(draftKey, drafts);
    renderFeedback();
  });
  $('[data-feedback-download]')?.addEventListener('click', exportNotes);

  document.querySelectorAll('[data-menu-button]').forEach(trigger => {
    const menu = document.getElementById(trigger.dataset.menuButton);
    if (!menu) return;
    trigger.addEventListener('click', () => menu.hidden ? openMenu(trigger, menu) : closeMenu(menu));
  });
  document.querySelectorAll('[data-menu-close]').forEach(item => item.addEventListener('click', () => {
    specimen(item.dataset.menuMessage || `${item.textContent.trim()} 선택은 검수용 local-only 시연입니다.`);
    closeMenu(item.closest('.menu'));
  }));

  document.querySelectorAll('[data-tabs]').forEach(group => {
    const tabs = [...group.querySelectorAll('[data-tab]')];
    tabs.forEach(tab => {
      tab.addEventListener('click', () => selectTab(tab));
      tab.addEventListener('keydown', event => {
        if (event.isComposing || !['ArrowLeft', 'ArrowRight', 'Home', 'End'].includes(event.key)) return;
        event.preventDefault();
        const index = tabs.indexOf(tab);
        const next = event.key === 'Home' ? tabs[0] : event.key === 'End' ? tabs.at(-1) : tabs[(index + (event.key === 'ArrowRight' ? 1 : -1) + tabs.length) % tabs.length];
        selectTab(next);
        next.focus({ preventScroll: true });
      });
    });
  });

  document.querySelectorAll('[data-segmented]').forEach(group => {
    group.querySelectorAll('button').forEach(button => button.addEventListener('click', () => {
      group.querySelectorAll('button').forEach(candidate => candidate.setAttribute('aria-pressed', String(candidate === button)));
      const preview = document.getElementById(group.dataset.segmented);
      if (preview) preview.textContent = `${button.textContent.trim()} 밀도는 이 카드 안에서만 미리 봅니다.`;
    }));
  });

  document.querySelectorAll('[data-dialog-open]').forEach(trigger => trigger.addEventListener('click', () => {
    const dialog = document.getElementById(trigger.dataset.dialogOpen);
    if (!dialog) return;
    dialogTrigger = trigger;
    dialog.showModal();
    dialog.querySelector('[data-dialog-initial]')?.focus({ preventScroll: true });
  }));
  document.querySelectorAll('[data-dialog-close]').forEach(button => button.addEventListener('click', () => document.getElementById(button.dataset.dialogClose)?.close()));
  document.querySelectorAll('dialog').forEach(dialog => dialog.addEventListener('close', () => {
    dialogTrigger?.focus({ preventScroll: true });
    dialogTrigger = null;
  }));

  document.querySelectorAll('[data-specimen-action]').forEach(button => button.addEventListener('click', () => specimen(button.dataset.specimenAction, document.getElementById(button.dataset.specimenResult || ''))));

  document.querySelectorAll('[data-composer]').forEach(composer => {
    const input = composer.querySelector('textarea');
    const send = composer.querySelector('[data-composer-send]');
    const result = composer.parentElement.querySelector('[data-composer-result]');
    const update = () => { send.disabled = !input.value.trim(); };
    input.addEventListener('input', update);
    input.addEventListener('keydown', event => {
      if (event.key !== 'Enter' || event.shiftKey || event.isComposing || !input.value.trim()) return;
      event.preventDefault();
      send.click();
    });
    send.addEventListener('click', () => {
      if (!input.value.trim()) return;
      result.textContent = `이 카드에서만 보이는 보낼 문장: ${input.value.trim()}`;
      input.value = '';
      update();
    });
    update();
  });

  document.addEventListener('keydown', event => {
    if (event.key !== 'Escape' || event.isComposing) return;
    document.querySelectorAll('.menu:not([hidden])').forEach(menu => closeMenu(menu));
  });
  document.addEventListener('keydown', event => {
    const item = event.target.closest?.('[role="menuitem"]');
    if (!item || event.isComposing || !['ArrowDown', 'ArrowUp', 'Home', 'End'].includes(event.key)) return;
    event.preventDefault();
    const items = [...item.closest('.menu').querySelectorAll('[role="menuitem"]')];
    const index = items.indexOf(item);
    const next = event.key === 'Home' ? items[0] : event.key === 'End' ? items.at(-1) : items[(index + (event.key === 'ArrowDown' ? 1 : -1) + items.length) % items.length];
    next.focus({ preventScroll: true });
  });

  renderFeedback();
})();
