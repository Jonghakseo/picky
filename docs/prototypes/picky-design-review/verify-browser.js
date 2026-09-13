// DS.01 standalone review-kit contract checks using isolated Chrome profiles.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { pathToFileURL } = require('node:url');
const { createRequire } = require('node:module');
const { execFileSync } = require('node:child_process');

const cli = process.env.PLAYWRIGHT_CLI || execFileSync('which', ['playwright-cli'], { encoding: 'utf8' }).trim();
const { chromium } = createRequire(fs.realpathSync(cli))('playwright-core');
const evidence = '/private/tmp/picky-design-ds01-evidence';
fs.mkdirSync(evidence, { recursive: true });

function contrast(hexA, hexB) {
  const channel = hex => {
    const values = hex.match(/[\da-f]{2}/gi).map(value => parseInt(value, 16) / 255);
    const linear = values.map(value => value <= .04045 ? value / 12.92 : ((value + .055) / 1.055) ** 2.4);
    return .2126 * linear[0] + .7152 * linear[1] + .0722 * linear[2];
  };
  const [a, b] = [channel(hexA), channel(hexB)];
  return (Math.max(a, b) + .05) / (Math.min(a, b) + .05);
}

async function main() {
  const browser = await chromium.launch({ channel: 'chrome', headless: true });
  const checks = [];
  const errors = [];
  const external = [];
  const directory = pathToFileURL(__dirname + '/').href;

  function observe(context) {
    context.on('page', candidate => {
      candidate.on('pageerror', error => errors.push(String(error)));
      candidate.on('console', message => { if (message.type() === 'error') errors.push(message.text()); });
    });
    context.on('request', request => { if (!request.url().startsWith(directory)) external.push(request.url()); });
  }

  async function create(options = {}) {
    const context = await browser.newContext({ viewport: { width: 1440, height: 1000 }, acceptDownloads: true, ...options });
    observe(context);
    const page = await context.newPage();
    page.on('pageerror', error => errors.push(String(error)));
    page.on('console', message => { if (message.type() === 'error') errors.push(message.text()); });
    return { context, page };
  }

  const url = file => pathToFileURL(path.join(__dirname, file)).href;
  const overflow = page => page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth);

  try {
    const { context, page } = await create();
    for (const theme of ['light', 'dark']) {
      for (const viewport of [{ width: 1440, height: 1000 }, { width: 1024, height: 900 }, { width: 390, height: 844 }]) {
        for (const file of ['index.html', 'controls.html', 'patterns.html']) {
          await page.setViewportSize(viewport);
          await page.goto(url(file));
          await page.getByLabel('화면 밝기').selectOption(theme);
          assert.equal(await overflow(page), true, `${file} ${theme} ${viewport.width}px overflowed`);
        }
      }
    }
    await page.setViewportSize({ width: 1440, height: 1000 });
    await page.goto(url('index.html'));
    await page.getByLabel('화면 밝기').selectOption('light');
    await page.screenshot({ path: path.join(evidence, 'foundations-light-1440.png'), fullPage: true });
    await page.goto(url('controls.html'));
    await page.setViewportSize({ width: 1024, height: 900 });
    await page.screenshot({ path: path.join(evidence, 'controls-light-1024.png'), fullPage: true });
    await page.goto(url('patterns.html'));
    await page.setViewportSize({ width: 1440, height: 1000 });
    await page.screenshot({ path: path.join(evidence, 'patterns-light-1440.png'), fullPage: true });
    checks.push('All three pages keep an unclipped document at 1440, 1024 and 390 in both appearances, with representative light screenshots.');

    await page.goto(url('controls.html'));
    const record = page.getByRole('tab', { name: '기록' });
    await page.getByRole('tab', { name: '진행' }).focus();
    await page.keyboard.press('End');
    assert.equal(await record.getAttribute('aria-selected'), 'true');
    assert.equal(await record.evaluate(element => document.activeElement === element), true);
    await page.keyboard.press('Home');
    assert.equal(await page.getByRole('tab', { name: '진행' }).getAttribute('aria-selected'), 'true');
    const menuTrigger = page.locator('[data-menu-button="control-menu"]');
    await menuTrigger.click();
    await page.keyboard.press('ArrowDown');
    assert.equal(await page.getByRole('menuitem', { name: '내보내기 상태 보기' }).evaluate(element => document.activeElement === element), true);
    await page.keyboard.press('Escape');
    assert.equal(await menuTrigger.getAttribute('aria-expanded'), 'false');
    assert.equal(await menuTrigger.evaluate(element => document.activeElement === element), true);
    await page.getByRole('button', { name: '촘촘하게' }).click();
    assert.equal(await page.getByRole('button', { name: '촘촘하게' }).getAttribute('aria-pressed'), 'true');
    const dialogTrigger = page.getByRole('button', { name: '루틴 삭제 설명 열기' });
    await dialogTrigger.click();
    await page.keyboard.press('Escape');
    assert.equal(await page.locator('#control-dialog').evaluate(element => !element.open), true);
    assert.equal(await dialogTrigger.evaluate(element => document.activeElement === element), true);
    checks.push('Tabs use roving keyboard focus, menus update expanded state and focus, dialog Escape returns focus, and density is a local preview.');

    await page.goto(url('patterns.html'));
    const input = page.getByRole('textbox', { name: '메시지', exact: true });
    const send = page.getByRole('button', { name: '보내기' });
    assert.equal(await send.isDisabled(), true);
    await input.fill('로컬 시연 문장');
    assert.equal(await send.isEnabled(), true);
    await send.click();
    assert(await page.getByText('이 카드에서만 보이는 보낼 문장: 로컬 시연 문장', { exact: true }).isVisible());
    await input.fill('조합 중 문장');
    await input.evaluate(element => element.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', isComposing: true, bubbles: true, cancelable: true })));
    assert.equal(await input.inputValue(), '조합 중 문장');
    await page.getByLabel('나중에 예약 선택').click();
    await page.getByRole('menuitem', { name: '30분 후' }).click();
    assert(await page.getByText('30분 후는 one-shot 예약 선택 예시입니다. 실제 예약을 만들지 않았습니다.', { exact: true }).isVisible());
    const handoff = page.getByRole('button', { name: 'Picky와 루나의 읽기 전용 예시 열기' });
    await handoff.click();
    assert(await page.getByRole('dialog', { name: 'Picky ↔ 루나 · 보기 전용 예시' }).isVisible());
    await page.getByRole('button', { name: '읽기 전용 예시 닫기' }).click();
    assert.equal(await handoff.evaluate(element => document.activeElement === element), true);
    checks.push('The split composer has a disabled empty send, local-only send and schedule selection, IME protection, and read-only handoff dialog.');

    await page.goto(url('index.html'));
    await page.evaluate(() => { window.name = 'design-review-tab'; });
    await page.locator('[data-feedback-section]').selectOption('타이포그래피');
    await page.getByLabel('의견').fill('기초 <b>그대로</b> 의견');
    await page.getByRole('link', { name: '컨트롤', exact: true }).click();
    await page.getByLabel('의견').fill('컨트롤의 미저장 의견');
    await page.getByRole('link', { name: '기초', exact: true }).click();
    assert.equal(await page.getByLabel('의견').inputValue(), '기초 <b>그대로</b> 의견');
    assert.equal(await page.locator('[data-feedback-section]').inputValue(), '타이포그래피');
    await page.evaluate(() => { window.name = 'design-review-tab'; });
    await page.getByRole('button', { name: '의견 담기' }).click();
    assert.equal(await page.evaluate(() => window.name), 'design-review-tab', 'Review content must not be carried in the browsing-context name');
    await page.goto(url('patterns.html'));
    await page.getByLabel('의견').fill('패턴 <b>그대로</b> 의견');
    await page.getByRole('button', { name: '의견 담기' }).click();
    await page.reload();
    assert((await page.locator('[data-feedback-list]').innerText()).includes('패턴 <b>그대로</b> 의견'));
    const download = page.waitForEvent('download');
    await page.getByRole('button', { name: '모든 의견 Markdown 내려받기' }).click();
    const file = await download;
    assert.equal(file.suggestedFilename(), 'picky-design-ds01-feedback.md');
    const exportPath = path.join(evidence, 'feedback.md');
    await file.saveAs(exportPath);
    const markdown = fs.readFileSync(exportPath, 'utf8');
    assert(markdown.includes('기초 · 타이포그래피'));
    assert(markdown.includes('패턴 · Roster, 상태, unread'));
    assert(markdown.includes('기초 <b>그대로</b> 의견'));
    assert(markdown.includes('패턴 <b>그대로</b> 의견'));
    assert(markdown.includes('승인이나 적용을 의미하지 않습니다.'));
    checks.push('Feedback drafts preserve page and section; all-page literal notes persist and export without approval or copying private text into the browsing-context name.');
    await context.close();

    const reduced = await create({ reducedMotion: 'reduce', viewport: { width: 390, height: 844 } });
    await reduced.page.goto(url('patterns.html'));
    await reduced.page.getByLabel('화면 밝기').selectOption('dark');
    assert.equal(await overflow(reduced.page), true);
    const reducedStatus = reduced.page.getByRole('img', { name: '조율 중', exact: true });
    assert(await reducedStatus.isVisible());
    assert.equal(await reducedStatus.evaluate(element => element.getAnimations({ subtree: true }).length), 0);
    await reduced.page.screenshot({ path: path.join(evidence, 'patterns-dark-reduced-motion-390.png'), fullPage: true });
    checks.push('Reduce Motion leaves the visible broken ring static at 390px.');
    await reduced.context.close();

    const blockedContext = await browser.newContext({ viewport: { width: 390, height: 844 }, acceptDownloads: true });
    await blockedContext.addInitScript(() => {
      Storage.prototype.getItem = () => { throw new DOMException('blocked', 'SecurityError'); };
      Storage.prototype.setItem = () => { throw new DOMException('blocked', 'SecurityError'); };
    });
    observe(blockedContext);
    const blocked = await blockedContext.newPage();
    blocked.on('pageerror', error => errors.push(String(error)));
    blocked.on('console', message => { if (message.type() === 'error') errors.push(message.text()); });
    await blocked.goto(url('controls.html'));
    assert((await blocked.locator('[data-feedback-storage]').innerText()).includes('임시 상태'));
    await blocked.getByLabel('의견').fill('저장 차단 <b>literal</b>');
    await blocked.getByRole('button', { name: '의견 담기' }).click();
    assert((await blocked.locator('[data-feedback-list]').innerText()).includes('저장 차단 <b>literal</b>'));
    const blockedDownload = blocked.waitForEvent('download');
    await blocked.getByRole('button', { name: '모든 의견 Markdown 내려받기' }).click();
    const blockedFile = await blockedDownload;
    await blockedFile.saveAs(path.join(evidence, 'blocked-storage-feedback.md'));
    assert(fs.readFileSync(path.join(evidence, 'blocked-storage-feedback.md'), 'utf8').includes('저장 차단 <b>literal</b>'));
    await blockedContext.close();
    checks.push('Blocked browser storage preserves feedback in the current document and still exports literal Markdown.');

    const corruptContext = await browser.newContext({ viewport: { width: 390, height: 844 } });
    observe(corruptContext);
    const corrupt = await corruptContext.newPage();
    corrupt.on('pageerror', error => errors.push(String(error)));
    corrupt.on('console', message => { if (message.type() === 'error') errors.push(message.text()); });
    await corrupt.goto(url('index.html'));
    await corrupt.evaluate(() => {
      localStorage.setItem('picky.design.ds01.review', '[null,{"page":"bad","section":42,"text":null,"at":"never"}]');
      localStorage.setItem('picky.design.ds01.drafts', '{"bad":null}');
      localStorage.setItem('picky.design.ds01.theme', 'corrupt');
    });
    await corrupt.reload();
    assert(await corrupt.getByText('기초 검수 의견', { exact: true }).isVisible());
    assert.equal(await corrupt.locator('html').getAttribute('data-theme'), 'light');
    await corruptContext.close();
    checks.push('Corrupt or invalid stored feedback is rejected without breaking the review page.');

    const contrastReview = await create();
    for (const theme of ['light', 'dark']) {
      await contrastReview.page.setViewportSize({ width: 1440, height: 1000 });
      await contrastReview.page.goto(url('controls.html'));
      await contrastReview.page.getByLabel('화면 밝기').selectOption(theme);
      const primary = contrastReview.page.getByRole('button', { name: '변경 저장 상태 보기' });
      const normal = await primary.evaluate(element => ({ background: getComputedStyle(element).backgroundColor, color: getComputedStyle(element).color }));
      await primary.hover();
      const hover = await primary.evaluate(element => ({ background: getComputedStyle(element).backgroundColor, color: getComputedStyle(element).color }));
      await contrastReview.page.mouse.move(0, 0);
      await primary.focus();
      await contrastReview.page.keyboard.down('Space');
      const pressed = await primary.evaluate(element => ({ background: getComputedStyle(element).backgroundColor, color: getComputedStyle(element).color }));
      await contrastReview.page.keyboard.up('Space');
      const rgbToHex = rgb => '#' + rgb.match(/\d+/g).map(value => Number(value).toString(16).padStart(2, '0')).join('');
      assert(contrast(rgbToHex(normal.background), rgbToHex(normal.color)) >= 4.5, `${theme} normal action contrast`);
      assert(contrast(rgbToHex(hover.background), rgbToHex(hover.color)) >= 4.5, `${theme} hover action contrast`);
      assert(contrast(rgbToHex(pressed.background), rgbToHex(pressed.color)) >= 4.5, `${theme} keyboard-pressed action contrast`);
    }
    await contrastReview.context.close();
    checks.push('Primary action normal, hover and keyboard-pressed foreground/background pairs meet 4.5:1 contrast in both appearances.');
  } finally {
    await browser.close();
  }

  assert.deepEqual(errors, [], `Browser errors:\n${errors.join('\n')}`);
  assert.deepEqual(external, [], `External requests:\n${external.join('\n')}`);
  console.log(`DS.01 browser checks passed (${checks.length})`);
  checks.forEach((check, index) => console.log(`${index + 1}. ${check}`));
  console.log('Browser errors: 0');
  console.log('External requests: 0');
  console.log(`Evidence: ${evidence}`);
}

main().catch(error => { console.error(error.stack || error); process.exitCode = 1; });
