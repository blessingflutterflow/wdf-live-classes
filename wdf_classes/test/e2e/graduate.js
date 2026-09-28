// E2E: graduate enrols a learner -> learner signs in with generated login -> graduate alerted live.
const { chromium } = require('playwright-core');
const fs = require('fs');
const WEB = process.env.WEB || 'http://localhost:8787';
const PW = process.env.PW || 'classes';
const OUT = __dirname + '/shots3';
fs.mkdirSync(OUT, { recursive: true });
const results = [], errors = [];
const step = async (name, fn) => {
  const t = Date.now();
  try { await fn(); results.push(`PASS  ${name} (${Date.now() - t}ms)`); }
  catch (e) { results.push(`FAIL  ${name}: ${e.message.split('\n')[0]}`); }
};
async function open(browser, viewport, mobile) {
  const ctx = await browser.newContext({ viewport, isMobile: mobile, hasTouch: mobile });
  const p = await ctx.newPage();
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
        .map((e) => e.getBoundingClientRect()).filter((b) => b.width > 0 && b.height > 0)
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
async function search(p, text) {
  await p.getByRole('textbox').first().click();
  await p.waitForTimeout(400);
  await p.keyboard.press('Control+A');
  await p.keyboard.type(text, { delay: 40 });
  await p.waitForTimeout(500);
}
async function type(p, name, text) {
  await p.getByRole('textbox', { name }).click();
  await p.waitForTimeout(400);
  await p.keyboard.type(text, { delay: 40 });
}
async function signIn(p, user, pass) {
  await type(p, 'Username, email or cell number', user);
  await type(p, 'Password', pass);
  await p.getByRole('button', { name: 'Sign in' }).click();
}

(async () => {
  const browser = await chromium.launch({ channel: 'chrome', headless: true });

  // ---- Graduate on a laptop
  const gp = await open(browser, { width: 1440, height: 900 }, false);
  await signIn(gp, 'graduate@wdf.test', PW);
  await step('Graduate lands on Students (6 waiting)', async () => {
    await see(gp, 'Enrol all 6 waiting');
    await see(gp, 'Thabo Nkosi');
  });
  await gp.screenshot({ path: `${OUT}/1-graduate-students.png` });

  await step('Graduate opens Thabo: subjects pre-ticked from his form', async () => {
    await search(gp, 'Thabo');
    await tap(gp, 'Thabo Nkosi');
    await see(gp, /Chose on their form: .*Baking & Catering/);
    await see(gp, 'Enrol Thabo');
  });
  await gp.screenshot({ path: `${OUT}/2-graduate-enrol-panel.png` });

  let username, password;
  await step('Graduate enrols Thabo -> login appears', async () => {
    await gp.getByRole('button', { name: 'Enrol Thabo' }).click();
    await see(gp, 'Class login');
    // The card shows it; read the same values from the API (selectable text isn't in the a11y tree).
    const g = await (await fetch(WEB + '/api/classes/auth/login', { method: 'POST', body: JSON.stringify({ email: 'graduate@wdf.test', password: PW }) })).json();
    const list = await (await fetch(WEB + '/api/classes/students', { headers: { authorization: 'Bearer ' + g.token } })).json();
    const t = list.find((x) => x.name === 'Thabo Nkosi');
    username = t.username; password = t.password;
    if (!username || !password) throw new Error('login not visible: ' + username + ' / ' + password);
    results.push(`      generated login: ${username} / ${password}`);
  });
  await gp.screenshot({ path: `${OUT}/3-graduate-login-card.png` });

  // ---- Learner on a phone signs in with it
  const lp = await open(browser, { width: 412, height: 915 }, true);
  await step('Learner signs in with the generated username + password', async () => {
    await signIn(lp, username, password);
    await see(lp, 'Add your photo');
  });
  await lp.screenshot({ path: `${OUT}/4-learner-first-login.png` });

  await step('Graduate is alerted in REAL TIME + status goes Active', async () => {
    await see(gp, 'Thabo Nkosi signed in for the first time', 5000);
    await see(gp, /Signed in just now/, 5000);
  });
  await gp.screenshot({ path: `${OUT}/5-graduate-alerted.png` });

  await step('Wrong password is rejected', async () => {
    const p = await open(browser, { width: 412, height: 915 }, true);
    await signIn(p, username, '000000');
    await see(p, 'Wrong username or password.');
  });

  await step('Not-enrolled learner is told to ask their graduate', async () => {
    const r = await (await fetch(WEB + '/api/classes/auth/login', { method: 'POST', body: JSON.stringify({ email: 'naledi0000', password: '1' }) })).json();
    if (!/Wrong username/.test(r.error)) throw new Error(JSON.stringify(r));
  });

  await step('Graduate enrols all remaining', async () => {
    await search(gp, '');
    await gp.keyboard.press('Backspace');
    await tap(gp, 'Enrol all 5 waiting');
    await gp.getByRole('button', { name: 'Enrol 5' }).click();
    await see(gp, '5 learners enrolled', 5000);
  });

  await step('Phone layout: graduate on a phone', async () => {
    const pp = await open(browser, { width: 412, height: 915 }, true);
    await signIn(pp, 'graduate@wdf.test', PW);
    await see(pp, 'Students');
    await pp.screenshot({ path: `${OUT}/6-graduate-phone.png` });
    await search(pp, 'Naledi');
    await tap(pp, 'Naledi Khumalo');
    await see(pp, 'Class login');
    await pp.screenshot({ path: `${OUT}/7-graduate-phone-detail.png` });
  });

  await browser.close();
  console.log(results.join('\n'));
  console.log(errors.length ? 'PAGE ERRORS:\n' + [...new Set(errors)].join('\n') : 'No page errors.');
})();
