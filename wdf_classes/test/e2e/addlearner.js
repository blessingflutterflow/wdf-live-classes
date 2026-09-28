// E2E: a graduate adds a learner by hand (phone), gets the login, learner signs in.
const { chromium } = require('playwright-core');
const fs = require('fs');
const WEB = process.env.WEB || 'http://localhost:8787';
const PW = process.env.PW || 'classes';
const OUT = __dirname + '/shots4';
fs.mkdirSync(OUT, { recursive: true });
const results = [], errors = [];
const step = async (name, fn) => {
  const t = Date.now();
  try { await fn(); results.push(`PASS  ${name} (${Date.now() - t}ms)`); }
  catch (e) { results.push(`FAIL  ${name}: ${e.message.split('\n')[0]}`); }
};
async function open(browser, viewport, mobile) {
  const p = await (await browser.newContext({ viewport, isMobile: mobile, hasTouch: mobile })).newPage();
  p.on('pageerror', (e) => errors.push(e.message));
  await p.goto(WEB);
  await p.waitForSelector('flt-semantics-placeholder', { state: 'attached', timeout: 60000 });
  await p.evaluate(() => document.querySelector('flt-semantics-placeholder').click());
  return p;
}
async function find(p, text, timeout = 10000) {
  const re = text instanceof RegExp ? text.source : text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const end = Date.now() + timeout;
  while (Date.now() < end) {
    const box = await p.evaluate((src) => {
      const r = new RegExp(src);
      const hits = [...document.querySelectorAll('flt-semantics, span')]
        .filter((e) => r.test(e.getAttribute('aria-label') || '') || r.test(e.childElementCount ? '' : e.textContent || ''))
        .map((e) => e.getBoundingClientRect()).filter((b) => b.width > 0 && b.height > 0 && b.y >= 0 && b.y < innerHeight)
        .sort((a, b) => a.width * a.height - b.width * b.height);
      return hits[0] ? { x: hits[0].x + hits[0].width / 2, y: hits[0].y + hits[0].height / 2 } : null;
    }, re);
    if (box) return box;
    await p.waitForTimeout(200);
  }
  throw new Error(`not found: ${text}`);
}
const see = (p, t, ms) => find(p, t, ms);
async function tap(p, t) { const b = await find(p, t); await p.mouse.click(b.x, b.y); await p.waitForTimeout(400); }
async function type(p, name, text) {
  await p.getByRole('textbox', { name }).click();
  await p.waitForTimeout(400);
  await p.keyboard.type(text, { delay: 40 });
}
(async () => {
  const browser = await chromium.launch({ channel: 'chrome', headless: true });
  const gp = await open(browser, { width: 412, height: 915 }, true);
  await type(gp, 'Username, email or cell number', 'graduate@wdf.test');
  await type(gp, 'Password', PW);
  await gp.getByRole('button', { name: 'Sign in' }).click();
  await step('Graduate sees "Add learner"', async () => { await see(gp, 'Add learner'); });
  await step('Add learner form: name, cell, modules pre-ticked, pick skill', async () => {
    await gp.getByRole('button', { name: 'Add learner' }).click();
    await gp.waitForTimeout(900);
    await see(gp, 'Add a learner');
    await type(gp, 'Name and surname', 'Mpho Radebe');
    await type(gp, 'Cell number', '0761112222');
    await tap(gp, 'Hairdressing & Beauty');
    await gp.screenshot({ path: `${OUT}/1-add-learner-form.png` });
  });
  let login = {};
  await step('Add and enrol -> login card appears', async () => {
    await gp.getByRole('button', { name: 'Add and enrol' }).click();
    await see(gp, 'Class login', 8000);
    const g = await (await fetch(WEB + '/api/classes/auth/login', { method: 'POST', body: JSON.stringify({ email: 'graduate@wdf.test', password: PW }) })).json();
    const list = await (await fetch(WEB + '/api/classes/students', { headers: { authorization: 'Bearer ' + g.token } })).json();
    const s = list.find((x) => x.name === 'Mpho Radebe');
    if (!s || !s.enrolled) throw new Error('not enrolled');
    login = s;
    results.push(`      ${s.username} / ${s.password}, ${s.subjectIds.length} subjects`);
    await gp.screenshot({ path: `${OUT}/2-added-login-card.png` });
  });
  await step('The added learner signs in (photo gate)', async () => {
    const lp = await open(browser, { width: 412, height: 915 }, true);
    await type(lp, 'Username, email or cell number', login.username);
    await type(lp, 'Password', login.password);
    await lp.getByRole('button', { name: 'Sign in' }).click();
    await see(lp, 'Add your photo');
  });
  await browser.close();
  console.log(results.join('\n'));
  console.log(errors.length ? 'PAGE ERRORS:\n' + [...new Set(errors)].join('\n') : 'No page errors.');
})();
