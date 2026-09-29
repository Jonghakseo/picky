// Shared renderer for the dashboard update card prototype.
// States mirror the proposed PickyUpdaterController.dashboardUpdateState.

const ICONS = {
  download: '<svg viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M10 3v9m0 0 3.5-3.5M10 12 6.5 8.5M4 15.5h12"/></svg>',
  alert: '<svg viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><path d="M10 6v5m0 3v.01"/><circle cx="10" cy="10" r="7.2"/></svg>',
  close: '<svg viewBox="0 0 20 20" width="14" height="14" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><path d="m6 6 8 8m0-8-8 8"/></svg>'
};

const COPY = {
  ko: {
    readyTitle: v => `Picky ${v} 업데이트가 준비됐어요`,
    readyDetail: () => '지금 재시작하거나, 다음에 Picky를 종료할 때 설치돼요.',
    manualTitle: v => `Picky ${v} 업데이트가 있어요`,
    manualDetail: () => '업데이트 창에서 받고 설치해요.',
    failedTitle: 'Picky 업데이트를 준비하지 못했어요',
    failedDetail: '다시 시도하면 업데이트 창에서 이어서 진행해요.',
    install: '업데이트하고 재시작',
    installing: '재시작하는 중…',
    manual: '업데이트',
    retry: '다시 시도',
    notes: '새 기능 보기',
    later: '나중에',
    modalTitle: n => `진행 중인 Pickle이 ${n}개 있어요`,
    modalBody: '재시작하면 진행 중인 응답이 멈춰요. 대화 기록은 그대로 남아요.',
    cancel: '취소'
  },
  en: {
    readyTitle: v => `Picky ${v} is ready to install`,
    readyDetail: () => 'Restart now, or it installs the next time you quit Picky.',
    manualTitle: v => `Picky ${v} is available`,
    manualDetail: () => 'Download and install it from the update window.',
    failedTitle: "Couldn't prepare the Picky update",
    failedDetail: 'Try again to continue in the update window.',
    install: 'Update and Restart',
    installing: 'Restarting…',
    manual: 'Update',
    retry: 'Try Again',
    notes: "What's New",
    later: 'Later',
    modalTitle: n => `${n} Pickles are still working`,
    modalBody: 'Restarting stops their current responses. Conversations stay as they are.',
    cancel: 'Cancel'
  }
};

function renderUpdateCard({ state, lang = 'ko', version = '0.9.0', current = '0.8.3', hasNotes = true }) {
  const c = COPY[lang];
  if (state === 'hidden') return '';
  const isError = state === 'failed';
  let title, detail, primary;
  switch (state) {
    case 'ready':
      title = c.readyTitle(version); detail = c.readyDetail(current);
      primary = `<button class="btn primary" data-act="install">${c.install}</button>`; break;
    case 'installing':
      title = c.readyTitle(version); detail = c.readyDetail(current);
      primary = `<button class="btn primary" disabled><span class="spin"></span>${c.installing}</button>`; break;
    case 'manual':
      title = c.manualTitle(version); detail = c.manualDetail(current);
      primary = `<button class="btn primary" data-act="manual">${c.manual}</button>`; break;
    case 'failed':
      title = c.failedTitle; detail = c.failedDetail;
      primary = `<button class="btn" data-act="retry">${c.retry}</button>`; break;
  }
  const notes = hasNotes && !isError && state !== 'installing'
    ? `<button class="btn" data-act="notes">${c.notes}</button>` : '';
  const later = state === 'installing' ? ''
    : `<button class="btn plain" data-act="later" aria-label="${c.later}" title="${c.later}">${c.later}</button>`;
  return `
    <div class="upd ${isError ? 'error' : ''}" role="status">
      <div class="upd-icon" aria-hidden="true">${isError ? ICONS.alert : ICONS.download}</div>
      <div class="upd-text">
        <div class="upd-title">${title}${isError ? '' : `<span class="ver" aria-label="${current} → ${version}">${current} → ${version}</span>`}</div>
        <div class="upd-detail">${detail}</div>
      </div>
      <div class="upd-actions">${later}${notes}${primary}</div>
    </div>`;
}

function renderRunningModal({ lang = 'ko', pickles = ['결제 API 리팩터링', '릴리즈 노트 초안'] }) {
  const c = COPY[lang];
  return `
    <div class="backdrop" data-act="cancel-backdrop">
      <div class="modal" role="dialog" aria-modal="true">
        <h2>${c.modalTitle(pickles.length)}</h2>
        <p>${c.modalBody}</p>
        <ul>${pickles.map(p => `<li>${p}</li>`).join('')}</ul>
        <div class="row">
          <button class="btn" data-act="cancel">${c.cancel}</button>
          <button class="btn primary" data-act="confirm">${c.install}</button>
        </div>
      </div>
    </div>`;
}
