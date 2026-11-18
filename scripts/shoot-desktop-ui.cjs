// Takes screenshots of the Windows app's main screens against a stand-in desktop bridge, for visual review.
// node scripts/shoot-desktop-ui.cjs [outDir] [light|dark]
const { chromium } = require('@playwright/test');
const { spawn } = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');

const out = path.resolve(process.argv[2] || 'artifacts/visuals-polish');
const theme = process.argv[3] || 'dark';
fs.mkdirSync(out, { recursive: true });

(async () => {
  const server = spawn('python3', ['-m', 'http.server', '4179', '--bind', '127.0.0.1', '--directory', 'desktop-windows/renderer'], { stdio: 'ignore' });
  let browser;
  try {
    await new Promise(resolve => setTimeout(resolve, 400));
    browser = await chromium.launch({ executablePath: process.env.CHROMIUM_PATH || '/usr/bin/chromium', headless: true, args: ['--no-sandbox'] });
    const page = await browser.newPage({ viewport: { width: 1370, height: 900 } });
    page.setDefaultTimeout(4000);
    const errors = []; page.on('pageerror', error => errors.push(error.message));
    page.on('dialog', dialog => dialog.accept());
    await page.addInitScript(themeName => {
      localStorage.setItem('appearance', themeName);
      const id = () => crypto.randomUUID();
      const hive = { id: id(), name: 'Hive', purpose: 'Your AI assistant, powered by a CLI on this device.', color: 'white', isMain: true };
      const travel = { id: id(), name: 'Travel', purpose: 'Plans trips and keeps answers short.', color: 'teal' };
      const school = { id: id(), name: 'School', purpose: 'Homework helper', color: 'green' };
      const now = Date.now(), at = m => new Date(now - m * 60000).toISOString();
      let workspace = { version: 2, bots: [hive, travel, school], sessions: {}, entries: [
        { id: id(), botID: hive.id, kind: 'user', text: 'What is on my calendar tomorrow? Add a reminder to call the plumber at 9.', date: at(9) },
        { id: id(), botID: hive.id, kind: 'activity', text: 'Read Reminders', detail: 'apple_reminders result', date: at(8) },
        { id: id(), botID: hive.id, kind: 'bot', provider: 'Claude Code · sonnet', state: 'complete', date: at(8), text: 'Tomorrow you have **two meetings**:\n\n| Time | Event |\n| --- | --- |\n| 10:00 | Design review |\n| 14:30 | Dentist |\n\nI added *Call the plumber* to **Home** for 9:00.\n\n```js\nconst ok = true;\n```' },
        { id: id(), botID: hive.id, kind: 'user', text: 'Thanks! Message Sam on Telegram that I am running late.', date: at(2) },
        { id: id(), botID: hive.id, kind: 'bot', provider: 'Claude Code · sonnet', state: 'complete', date: at(1), text: 'Done — I sent Sam a Telegram message saying you are running about 10 minutes late.' },
      ] };
      const ok = value => ({ ok: true, value });
      const setup = { providers: [{ id: 'claude', name: 'Claude Code', install: 'npm install -g @anthropic-ai/claude-code', login: 'claude', guide: 'https://code.claude.com/docs/en/setup' }, { id: 'codex', name: 'Codex', install: 'npm install -g @openai/codex', login: 'codex login', guide: '' }], installed: [{ id: 'claude:fixture', provider: 'claude', name: 'Claude Code', path: 'C:/claude.exe', version: '2.1.0' }], selected: 'claude:fixture', complete: true };
      const channels = { bot: hive.id, channels: {
        telegram: { name: 'Telegram', enabled: true, configured: true, fields: { token: true }, state: { state: 'on', detail: '@hive_bot' }, approved: [{ id: '42', name: 'Sam', at: now - 86400000 }], pending: [{ name: 'Alex', code: '482913', at: now - 60000 }] },
        discord: { name: 'Discord', enabled: false, configured: false, fields: {}, state: { state: 'off', detail: '' }, approved: [], pending: [] },
        slack: { name: 'Slack', enabled: false, configured: false, fields: {}, state: { state: 'off', detail: '' }, approved: [], pending: [] },
        sms: { name: 'SMS', enabled: false, configured: false, fields: {}, state: { state: 'off', detail: '' }, approved: [], pending: [] },
        imessage: { name: 'iMessage', enabled: true, configured: true, fields: { apiKey: true }, state: { state: 'error', detail: 'Inkbox rejected the API key' }, approved: [], pending: [] },
      }, calls: { ready: false, listening: false }, voiceFields: [], people: { telegram: 1 } };
      const known = {
        load: async () => ok(workspace), save: async value => { workspace = value; return ok(value); },
        setupStatus: async () => ok(setup), scanCLIs: async () => ok(setup), chooseCLI: async () => ok(setup), checkLogin: async () => ok('Signed in'),
        composioStatus: async () => ok({ configured: true, toolkits: [{ slug: 'gmail', name: 'Gmail', enabled: true, connected: true }, { slug: 'googlecalendar', name: 'Google Calendar', enabled: true, connected: true }, { slug: 'notion', name: 'Notion', enabled: true, connected: false, status: 'Not connected' }] }),
        allowConnectedApps: async () => ok(true), listModels: async () => ok([]), listFiles: async () => ok([]), vaultList: async () => ok([]), skillsList: async () => ok([]),
        serversList: async () => ok([]), serversStatus: async () => ok({ active: false }), loadDrafts: async () => ok({}), pendingApprovals: async () => ok([]),
        channelsStatus: async () => ok(channels), channelsSetBot: async () => ok(channels), channelsConfigure: async () => ok(channels), channelsEnable: async () => ok(channels), channelsApprove: async () => ok(channels), channelsRemove: async () => ok(channels),
        proactiveStatus: async () => ok({ enabled: false, rules: {}, connected: { gmail: true, googlecalendar: true } }),
        cloudStatus: async () => ok({ phase: 'signedOut', feedback: 'Not signed in', signedIn: false, phones: [] }),
        webStatus: async () => ok({ enabled: false, running: false, users: [] }),
        approvalRules: async () => ok([]), cliKeysStatus: async () => ok({}), mediaKeysStatus: async () => ok({}), loginsList: async () => ok([]), ollamaModels: async () => ok([]),
        voiceSettings: async () => ok({}), localVoiceStatus: async () => ok({ installed: false }), checkUpdates: async () => ok({ current: '10.2.0', latest: '10.2.0' }),
      };
      window.desktop = new Proxy(known, { get: (target, key) => key in target ? target[key] : (String(key).startsWith('on') ? () => {} : async () => ok(null)) });
    }, theme);
    await page.goto('http://127.0.0.1:4179/index.html');
    await page.waitForTimeout(900);
    const shot = async name => { await page.waitForTimeout(350); await page.screenshot({ path: path.join(out, `${theme}-${name}.png`) }); };
    await shot('chat');
    await page.locator('#chat-heading').click(); await shot('inspector'); await page.keyboard.press('Escape');
    await page.evaluate(() => document.querySelector('#draft').focus()); await page.keyboard.type('Draft message'); await shot('composer');
    for (const tab of ['General', 'Channels', 'Servers', 'Permissions', 'Voice', 'Heads-ups']) {
      await page.evaluate(() => document.querySelector('#panel')?.close());
      await page.keyboard.press('Control+Comma');
      await page.locator('.settings-nav button', { hasText: tab }).first().click().catch(() => console.log('no tab', tab));
      await shot('settings-' + tab.toLowerCase().replace(/\W+/g, '-'));
    }
    await page.evaluate(() => document.querySelector('#panel')?.close());
    await page.locator('#apps-button').click(); await shot('apps');
    await page.evaluate(() => document.querySelector('#panel')?.close());
    await page.locator('#new-button').click(); await shot('new-bot');
    await page.evaluate(() => document.querySelector('#panel')?.close());
    await page.setViewportSize({ width: 420, height: 860 }); await shot('narrow');
    if (errors.length) console.log('page errors:', errors);
    console.log('saved to', out);
  } finally { await browser?.close(); server.kill(); }
})().catch(error => { console.error(error); process.exit(1); });
