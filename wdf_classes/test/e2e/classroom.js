// E2E on the real LiveKit server: one big stage, learners locked on join, hands up -> teacher
// Unmute/Mute, teacher screen share seen full-screen on a phone. Uses a brand-new class room.
const { chromium } = require('playwright-core');
const WEB = process.env.WEB || 'http://localhost:8787';
const PW = process.env.PW || 'classes';
const A = WEB + '/api/classes';
const OUT = __dirname + '/shots5';
require('fs').mkdirSync(OUT, { recursive: true });
const results = [], errors = [];
const step = async (name, fn) => {
  const t = Date.now();
  try { await fn(); results.push(`PASS  ${name} (${Date.now() - t}ms)`); }
  catch (e) { results.push(`FAIL  ${name}: ${e.message.split('\n')[0]}`); }
};
const api = async (path, opts = {}, token) =>
  (await fetch(A + path, { ...opts, headers: { 'content-type': 'application/json', ...(token ? { authorization: 'Bearer ' + token } : {}) } })).json();
const login = (email) => api('/auth/login', { method: 'POST', body: JSON.stringify({ email, password: PW }) });
const until = async (fn, ms = 10000) => { const end = Date.now() + ms; while (Date.now() < end) { if (await fn()) return; await new Promise((r) => setTimeout(r, 400)); } throw new Error('timed out'); };

async function open(browser, viewport, mobile, auth, id) {
  const ctx = await browser.newContext({ viewport, isMobile: mobile, hasTouch: mobile, permissions: ['camera', 'microphone'] });
  await ctx.addInitScript(([tok, user]) => {
    localStorage.setItem('flutter.token', JSON.stringify(tok));
    localStorage.setItem('flutter.user', JSON.stringify(JSON.stringify(user)));
  }, [auth.token, auth.user]);
  const p = await ctx.newPage();
  p.on('pageerror', (e) => errors.push(e.message));
  await p.goto(`${WEB}/#/class/${id}`);
  await p.waitForSelector('flt-semantics-placeholder', { state: 'attached', timeout: 60000 });
  await p.evaluate(() => document.querySelector('flt-semantics-placeholder').click());
  await p.getByRole('button', { name: 'Leave' }).waitFor({ timeout: 30000 });
  return p;
}
const has = async (p, name) => (await p.getByRole('button', { name, exact: true }).count()) > 0;
const liveVideos = (p) => p.evaluate(() => {
  const all = []; const walk = (r) => r.querySelectorAll('*').forEach((e) => { if (e.tagName === 'VIDEO') all.push(e); if (e.shadowRoot) walk(e.shadowRoot); });
  walk(document); return all.filter((v) => v.videoWidth > 0).map((v) => `${v.videoWidth}x${v.videoHeight}`);
});

(async () => {
  const t = await login('teacher@wdf.test');
  const l = await login('learner@wdf.test');
  const jpeg = Buffer.from('/9j/4AAQSkZJRgABAQEASABIAAD/2wBDAP' + 'A'.repeat(2000), 'base64');
  await fetch(A + '/me/photo', { method: 'POST', headers: { authorization: 'Bearer ' + l.token, 'content-type': 'application/octet-stream' }, body: jpeg });
  l.user = await api('/me', {}, l.token);
  const title = 'Stage test ' + Date.now();
  await api('/sessions', { method: 'POST', body: JSON.stringify({ subjectId: 's1', title, description: '', startsAt: new Date(Date.now() - 60000).toISOString(), minutes: 60 }) }, t.token);
  const id = (await api('/sessions', {}, t.token)).find((s) => s.title === title).id;
  const join = await api(`/sessions/${id}/join`, { method: 'POST' }, t.token);
  const lk = join.url.replace(/^ws/, 'http');
  const learnerSources = async () => {
    const r = await (await fetch(`${lk}/twirp/livekit.RoomService/ListParticipants`, {
      method: 'POST', headers: { authorization: 'Bearer ' + join.token, 'content-type': 'application/json' }, body: JSON.stringify({ room: 'class-' + id }),
    })).json();
    const p = (r.participants || []).find((x) => x.identity === 'l1');
    return (p?.tracks || []).filter((tr) => !tr.muted).map((tr) => String(tr.source));
  };
  const micOn = async () => (await learnerSources()).some((s) => s === 'MICROPHONE' || s === '2');

  const browser = await chromium.launch({
    channel: 'chrome', headless: true,
    args: ['--use-fake-ui-for-media-stream', '--use-fake-device-for-media-stream', '--auto-select-desktop-capture-source=Entire screen', '--enable-usermedia-screen-capturing'],
  });
  const tp = await open(browser, { width: 1366, height: 820 }, false, t, id);
  const lp = await open(browser, { width: 412, height: 915 }, true, l, id);

  await step('Learner: locked on join (Muted, no Camera button), sees the teacher on one big stage', async () => {
    if (!(await has(lp, 'Muted'))) throw new Error('no Muted lock');
    if (await has(lp, 'Camera')) throw new Error('learner has a camera button');
    await until(async () => (await liveVideos(lp)).length === 1, 10000); // exactly one video: the teacher
  });
  await lp.screenshot({ path: `${OUT}/1-learner-stage.png` });
  await step('Learner tapping the mic does NOT unmute (server refuses)', async () => {
    await lp.getByRole('button', { name: 'Muted' }).click();
    await new Promise((r) => setTimeout(r, 3000));
    if (await micOn()) throw new Error('learner unmuted themselves');
  });
  await step('Learner raises hand -> teacher sees "Hands up 1"', async () => {
    await lp.getByRole('button', { name: 'Hand' }).click();
    await tp.getByRole('button', { name: 'Hands up 1' }).waitFor({ timeout: 8000 });
  });
  await step('Teacher opens hands list -> Unmute -> learner mic ON', async () => {
    await tp.getByRole('button', { name: 'Hands up 1' }).click();
    await tp.waitForTimeout(700);
    await tp.getByRole('button', { name: 'Unmute' }).first().click();
    await until(micOn, 12000);
  });
  await tp.screenshot({ path: `${OUT}/2-teacher-people.png` });
  await step('Teacher Mute -> learner mic OFF and locked again', async () => {
    await tp.getByRole('button', { name: 'Mute', exact: true }).first().click();
    await until(async () => !(await micOn()));
    await lp.getByRole('button', { name: 'Muted' }).waitFor({ timeout: 8000 });
  });
  await step('Teacher shares screen -> phone learner sees it', async () => {
    await tp.getByRole('button', { name: 'Share' }).click();
    await lp.getByRole('button', { name: 'Full screen' }).waitFor({ timeout: 15000 });
    await until(async () => (await liveVideos(lp)).length >= 1, 10000);
  });
  await lp.screenshot({ path: `${OUT}/3-learner-sees-share.png` });
  await step('Phone: Full screen hides everything else; Exit brings controls back', async () => {
    await lp.getByRole('button', { name: 'Full screen' }).click();
    await lp.getByRole('button', { name: 'Exit full screen' }).waitFor({ timeout: 5000 });
    if (await has(lp, 'Leave')) throw new Error('controls still visible');
    await lp.screenshot({ path: `${OUT}/4-learner-fullscreen.png` });
    await lp.getByRole('button', { name: 'Exit full screen' }).click();
    await lp.getByRole('button', { name: 'Leave' }).waitFor({ timeout: 5000 });
  });
  await step('Teacher stops sharing -> learner back to teacher view', async () => {
    await tp.getByRole('button', { name: 'Stop' }).click();
    await until(async () => !(await has(lp, 'Full screen')), 10000);
  });
  await browser.close();
  await api(`/sessions/${id}`, { method: 'DELETE' }, t.token);
  console.log(results.join('\n'));
  console.log(errors.length ? 'PAGE ERRORS:\n' + [...new Set(errors)].join('\n') : 'No page errors.');
})();
