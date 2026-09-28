// E2E: photo gate, assignments, upload, real-time notifications, marking, extensions.
const { chromium } = require('playwright-core');
const fs = require('fs');
const WEB = process.env.WEB || 'http://localhost:8787';
const PW = process.env.PW || 'classes';
const OUT = __dirname + '/shots2';
fs.mkdirSync(OUT, { recursive: true });

const results = [];
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
async function signIn(p, email) {
  // Tap + type like a person (works for touch and mouse contexts).
  await p.getByRole('textbox', { name: 'Username, email or cell number' }).click();
  await p.waitForTimeout(400);
  await p.keyboard.type(email, { delay: 40 });
  await p.getByRole('textbox', { name: 'Password' }).click();
  await p.waitForTimeout(400);
  await p.keyboard.type(PW, { delay: 40 });
  await p.getByRole('button', { name: 'Sign in' }).click();
}

// Flutter merges a card's texts into one accessibility node, so match text
// anywhere in a node's text OR aria-label, and click the smallest match.
async function find(p, text, timeout = 10000) {
  const re = text instanceof RegExp ? text.source : text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const flags = text instanceof RegExp ? text.flags : '';
  const end = Date.now() + timeout;
  while (Date.now() < end) {
    const box = await p.evaluate(([src, fl]) => {
      const r = new RegExp(src, fl);
      const hits = [...document.querySelectorAll('flt-semantics, flt-semantics-container, span')]
        .filter((e) => r.test(e.getAttribute('aria-label') || '') || r.test(e.childElementCount ? '' : e.textContent || ''))
        .map((e) => e.getBoundingClientRect()).filter((b) => b.width > 0 && b.height > 0)
        .sort((a, b) => a.width * a.height - b.width * b.height);
      return hits[0] ? { x: hits[0].x + hits[0].width / 2, y: hits[0].y + hits[0].height / 2 } : null;
    }, [re, flags]);
    if (box) return box;
    await p.waitForTimeout(200);
  }
  throw new Error(`not found: ${text}`);
}
const see = (p, text, timeout) => find(p, text, timeout);
async function tap(p, text, timeout) { const b = await find(p, text, timeout); await p.mouse.click(b.x, b.y); await p.waitForTimeout(300); }
async function typeInto(p, loc, text) {
  await loc.click();
  await p.waitForTimeout(400);
  await p.keyboard.type(text, { delay: 25 });
}
async function nav(p, path) {
  await p.goto(WEB + '/#' + path);
  await p.reload();
  await p.waitForSelector('flt-semantics-placeholder', { state: 'attached', timeout: 60000 });
  await p.evaluate(() => document.querySelector('flt-semantics-placeholder').click());
  await p.waitForTimeout(800);
}
async function pick(p, click, file) {
  const [chooser] = await Promise.all([p.waitForEvent('filechooser', { timeout: 10000 }), click()]);
  await chooser.setFiles(file);
}
const errors = [];

(async () => {
  const browser = await chromium.launch({ channel: 'chrome', headless: true });
  // test files
  const pdf = __dirname + '/cv.pdf';
  fs.writeFileSync(pdf, '%PDF-1.4\n1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj 2 0 obj<</Type/Pages/Kids[]/Count 0>>endobj\ntrailer<</Root 1 0 R>>\n%%EOF');
  const face = __dirname + '/face.jpg';

  // ---- Learner (phone)
  const lp = await open(browser, { width: 412, height: 915 }, true);
  await lp.setContent('<body style="margin:0;background:#f4c9a8"><div style="width:400px;height:400px;border-radius:50%;background:#8a5a3b;margin:40px"></div></body>');
  await lp.screenshot({ path: face, type: 'jpeg', clip: { x: 0, y: 0, width: 480, height: 480 } });
  await lp.goto(WEB);
  await lp.waitForSelector('flt-semantics-placeholder', { state: 'attached', timeout: 60000 });
  await lp.evaluate(() => document.querySelector('flt-semantics-placeholder').click());
  await signIn(lp, 'learner@wdf.test');

  await step('Learner is forced to add a photo first', async () => { await see(lp, 'Add your photo', 10000); });
  await lp.screenshot({ path: `${OUT}/1-learner-photo-gate.png` });
  await step('Learner uploads photo -> lands on classes', async () => {
    await pick(lp, () => lp.getByRole('button', { name: 'Choose a photo' }).click(), face);
    await lp.getByRole('button', { name: 'Use this photo' }).click();
    await see(lp, /here are your classes/, 10000);
  });
  await lp.screenshot({ path: `${OUT}/2-learner-classes.png` });

  await step('Learner sees assignments grouped (To do / Marked)', async () => {
    await nav(lp, '/assignments');
    await see(lp, 'Write your CV', 10000);
    await see(lp, 'Monthly budget plan');
    await see(lp, 'Marked 85%');
  });
  await lp.screenshot({ path: `${OUT}/3-learner-assignments.png`, fullPage: true });

  // ---- Teacher (laptop) — open before the learner submits, to see it arrive live
  const tp = await open(browser, { width: 1440, height: 900 }, false);
  await signIn(tp, 'teacher@wdf.test');
  await step('Teacher signs in', async () => { await see(tp, 'Your timetable', 10000); });
  await tp.screenshot({ path: `${OUT}/3b-teacher-after-login.png` });
  await nav(tp, '/assignments');
  await step('Teacher sees submission progress', async () => { await see(tp, /0 of 2 submitted/, 10000); });
  await tp.screenshot({ path: `${OUT}/4-teacher-assignments.png` });

  await step('Learner uploads PDF for "Write your CV"', async () => {
    await tap(lp, 'Write your CV');
    await pick(lp, () => lp.getByRole('button', { name: 'Upload PDF or Word' }).click(), pdf);
    await lp.getByRole('button', { name: 'Replace file' }).waitFor({ timeout: 15000 });
  });
  await lp.screenshot({ path: `${OUT}/5-learner-submitted.png` });

  await step('Teacher gets REAL-TIME "submitted" alert + list updates', async () => {
    const s = Date.now();
    await see(tp, 'Lerato Mokoena submitted', 5000);
    results.push(`      alert arrived ${Date.now() - s}ms after upload finished`);
    await see(tp, /1 of 2 submitted/, 5000);
  });
  await tp.screenshot({ path: `${OUT}/6-teacher-live-alert.png` });

  await step('Teacher opens two-pane marking and marks 88%', async () => {
    await tap(tp, 'Write your CV');
    await tap(tp, 'Lerato Mokoena');
    await typeInto(tp, tp.getByRole('textbox', { name: 'Mark' }), '88');
    await typeInto(tp, tp.getByRole('textbox', { name: 'Feedback for the learner' }), 'Well structured CV. Add your volunteer work.');
    await tp.screenshot({ path: `${OUT}/7-teacher-marking.png` });
    await tp.getByRole('button', { name: 'Return to learner' }).click();
    await see(tp, /got 88%/, 5000);
  });

  await step('Learner gets REAL-TIME mark + sees 88% and feedback', async () => {
    await see(lp, 'Marked: Write your CV', 5000);
    await see(lp, '88%', 5000);
    await see(lp, 'Well structured CV. Add your volunteer work.');
  });
  await lp.screenshot({ path: `${OUT}/8-learner-marked.png` });

  await step('Teacher extends a deadline for everyone -> learner alerted', async () => {
    await nav(tp, '/assignments/a3');
    await tp.getByRole('button', { name: 'Show menu' }).click();
    await tp.getByRole('menuitem', { name: 'Extend deadline for everyone' }).click();
    await tp.getByRole('button', { name: 'Extend' }).click();
    await see(lp, 'Deadline extended: Monthly budget plan', 5000);
  });

  await step('Teacher posts a new assignment -> learner alerted', async () => {
    await nav(tp, '/assignments');
    await tp.getByRole('button', { name: 'New assignment' }).click();
    await tp.waitForTimeout(1000);
    await tap(tp, 'Job Readiness');
    await typeInto(tp, tp.getByRole('textbox', { name: 'Title' }), 'Cover letter');
    await typeInto(tp, tp.getByRole('textbox', { name: 'Instructions' }), 'Write a one-page cover letter for a job you want.');
    await tp.screenshot({ path: `${OUT}/9-teacher-new-assignment.png` });
    await tp.getByRole('button', { name: 'Post assignment' }).click();
    await see(lp, 'New assignment: Cover letter', 5000);
  });

  await step('Alerts tab shows unread notifications', async () => {
    await nav(lp, '/notifications');
    await see(lp, 'Marked: Write your CV', 10000);
    await lp.getByRole('button', { name: 'Mark all read' }).waitFor();
  });
  await lp.screenshot({ path: `${OUT}/10-learner-alerts.png` });

  await browser.close();
  console.log(results.join('\n'));
  console.log(errors.length ? 'PAGE ERRORS:\n' + [...new Set(errors)].join('\n') : 'No page errors.');
})();
