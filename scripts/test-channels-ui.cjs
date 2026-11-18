// Settings → Channels (10.2), in a real browser against a stand-in for the desktop bridge. The engine itself is covered by
// desktop-windows/app/channels.test.cjs and channels-host.test.cjs; this checks the screen: states, set-up forms that never echo a
// saved token, approving with a code, removing a person, choosing the Bot, and that names from strangers can never become markup.
const { chromium } = require('@playwright/test');
const { spawn } = require('node:child_process');
const assert = require('node:assert/strict');

(async () => {
  const server = spawn('python3', ['-m', 'http.server', '4177', '--bind', '127.0.0.1', '--directory', 'desktop-windows/renderer'], { stdio: 'ignore' });
  let browser;
  try {
    await new Promise((resolve, reject) => { server.once('error', reject); setTimeout(resolve, 300); });
    browser = await chromium.launch({ executablePath: process.env.CHROMIUM_PATH || '/usr/bin/chromium', headless: true, args: ['--no-sandbox'] });
    const page = await browser.newPage({ viewport: { width: 1370, height: 940 } });
    page.setDefaultTimeout(8000);
    const errors = []; page.on('pageerror', error => errors.push(error.message));
    page.on('dialog', dialog => dialog.accept());
    await page.addInitScript(() => {
      const hive = { id: '11111111-1111-4111-8111-111111111111', name: 'Hive', purpose: 'Main', color: 'white', isMain: true };
      const travel = { id: '22222222-2222-4222-8222-222222222222', name: 'Travel', purpose: 'Trips', color: 'teal' };
      let workspace = { version: 2, bots: [hive, travel], entries: [], sessions: {} };
      const calls = []; window.__calls = calls;
      const ok = value => ({ ok: true, value }), fail = error => ({ ok: false, error });
      const blank = name => ({ name, enabled: false, configured: false, fields: {}, state: { state: 'off', detail: '' }, approved: [], pending: [] });
      const state = { bot: null, channels: { telegram: blank('Telegram'), discord: blank('Discord'), slack: blank('Slack'), sms: blank('SMS'), imessage: blank('iMessage') }, calls: { ready: false, listening: false }, voiceFields: [], people: {} };
      const copy = () => ok(structuredClone(state));
      const setup = { providers: [], installed: [{ id: 'codex:x', provider: 'codex', name: 'Codex', path: '/x', version: '1' }], selected: 'codex:x', complete: true };
      window.desktop = {
        load: async () => ok(workspace), save: async value => { workspace = value; return ok(value); }, setupStatus: async () => ok(setup), scanCLIs: async () => ok(setup),
        onChange: () => {}, listModels: async () => ok([]), listFiles: async () => ok([]), composioStatus: async () => ok({ configured: false, toolkits: [] }), openDocs: async url => { calls.push(['openDocs', url]); return ok(true); },
        channelsStatus: async () => copy(),
        channelsSetBot: async id => { calls.push(['setBot', id]); state.bot = id; return copy(); },
        channelsConfigure: async (id, fields) => {
          calls.push(['configure', id, fields]);
          const c = state.channels[id]; for (const [key, value] of Object.entries(fields)) c.fields[key] = /token|key|pin/i.test(key) ? true : value;
          c.configured = id === 'telegram' ? !!c.fields.token : c.configured; return copy();
        },
        channelsEnable: async (id, on) => {
          calls.push(['enable', id, on]);
          if (!state.bot) return fail('Choose which Bot answers first.');
          const c = state.channels[id]; c.enabled = on; c.state = on ? { state: 'on', detail: '@hive_bot' } : { state: 'off', detail: '' };
          if (on) c.pending = [{ name: '<img src=x onerror="window.__pwned=1">Mallory', code: '123456', at: Date.now() - 120000 }];
          return copy();
        },
        channelsApprove: async (id, code) => {
          calls.push(['approve', id, code]);
          const c = state.channels[id]; const entry = c.pending.find(x => x.code === code);
          if (!entry) return fail('That code is not waiting. Ask them to message the Bot again to get a new one.');
          c.pending = []; c.approved.push({ id: '42', name: entry.name, at: Date.now() }); return copy();
        },
        channelsRemove: async (id, who) => { calls.push(['remove', id, who]); state.channels[id].approved = state.channels[id].approved.filter(x => x.id !== who); return copy(); },
      };
    });
    await page.goto('http://127.0.0.1:4177/index.html');
    await page.locator('#chat-heading').getByText('Hive', { exact: true }).waitFor();
    await page.keyboard.press('Control+Comma');
    await page.locator('.settings-nav button', { hasText: 'Channels' }).click();
    const card = id => page.locator(`.channel-card[data-channel="${id}"]`);
    await card('telegram').waitFor();
    assert.equal(await page.locator('.channel-card').count(), 5, 'every channel has a card');
    assert.equal(await card('telegram').locator('.status-badge').textContent(), 'Not set up');
    assert.equal(await card('telegram').locator('input.switch').isDisabled(), true, 'a channel cannot be turned on before it is set up');

    // Set up Telegram. The token is sent once and never shown again.
    await card('telegram').getByRole('button', { name: 'Set up' }).click();
    assert.equal(await card('telegram').locator('.channel-steps li').count(), 3);
    await card('telegram').getByLabel('Bot token').fill('123:SECRET');
    await card('telegram').getByRole('button', { name: 'Save' }).click();
    await page.waitForFunction(() => window.__calls.some(([name]) => name === 'configure'));
    assert.deepEqual((await page.evaluate(() => window.__calls)).find(([name]) => name === 'configure'), ['configure', 'telegram', { token: '123:SECRET' }]);
    assert.equal(await card('telegram').getByLabel('Bot token').inputValue(), '', 'a saved token is never put back in the field');
    assert.match(await card('telegram').getByLabel('Bot token').getAttribute('placeholder'), /Saved/);
    // Saving again with the field empty keeps the token (it is not sent at all).
    await card('telegram').getByRole('button', { name: 'Save' }).click();
    await page.waitForFunction(() => window.__calls.filter(([name]) => name === 'configure').length === 2);
    assert.deepEqual((await page.evaluate(() => window.__calls)).filter(([name]) => name === 'configure')[1][2], {});

    // No Bot chosen yet: the switch explains itself and stays off.
    assert.equal(await card('telegram').locator('input.switch').isDisabled(), true, 'a channel needs a Bot first');
    await page.getByLabel('Bot that answers on channels').selectOption({ label: 'Travel' });
    await page.waitForFunction(() => window.__calls.some(([name]) => name === 'setBot'));
    assert.equal(await card('telegram').locator('input.switch').isDisabled(), false);
    await card('telegram').locator('input.switch').check();
    await card('telegram').locator('.status-badge.on').waitFor();
    assert.match(await card('telegram').locator('.status-badge').textContent(), /On · @hive_bot/);

    // A stranger is waiting. Their name stays text; a wrong code is refused; the right one approves them.
    const pending = card('telegram').locator('.pending-row');
    await pending.waitFor();
    assert.match(await pending.locator('strong').textContent(), /<img src=x/);
    assert.equal(await page.evaluate(() => window.__pwned), undefined, 'a name from a stranger never becomes markup');
    await pending.locator('.code-field').fill('000000'); await pending.getByRole('button', { name: 'Approve' }).click();
    await page.locator('#toast.visible', { hasText: 'That code is not waiting' }).waitFor();
    await pending.locator('.code-field').fill('123456'); await pending.getByRole('button', { name: 'Approve' }).click();
    await card('telegram').locator('.person-row').waitFor();
    assert.equal(await card('telegram').locator('.pending-row').count(), 0);
    await card('telegram').locator('.person-row').getByRole('button', { name: 'Remove' }).click();
    await page.waitForFunction(() => window.__calls.some(([name]) => name === 'remove'));
    assert.equal(await card('telegram').locator('.person-row').count(), 0);

    // The guide link opens in the browser.
    await card('telegram').getByRole('button', { name: /Open the guide/ }).click();
    await page.waitForFunction(() => window.__calls.some(([name]) => name === 'openDocs'));
    await page.screenshot({ path: 'artifacts/visuals-channels/channels.png' }).catch(() => {});
    assert.deepEqual(errors, []);
    console.log('PASS: channels settings — states, set-up form never echoes saved tokens, Bot choice gates the switch, approve with a code (wrong code refused), remove, hostile names stay text.');
  } finally { if (browser) await browser.close(); server.kill(); }
})().catch(error => { console.error(error); process.exit(1); });
