// E2E against the real LiveKit server: teacher "Mute all" locks learner mics; raised hand ->
// "Let speak" -> learner's mic comes on; "Unmute all" unlocks. Uses a brand-new class room.
const { chromium } = require('playwright-core');
const WEB = process.env.WEB || 'http://localhost:8787';
const PW = process.env.PW || 'classes';
const A = WEB + '/api/classes';
const results = [], errors = [];
const step = async (name, fn) => {
  const t = Date.now();
  try { await fn(); results.push(`PASS  ${name} (${Date.now() - t}ms)`); }
  catch (e) { results.push(`FAIL  ${name}: ${e.message.split('\n')[0]}`); }
};
const api = async (path, opts = {}, token) =>
  (await fetch(A + path, { ...opts, headers: { 'content-type': 'application/json', ...(token ? { authorization: 'Bearer ' + token } : {}) } })).json();
const login = async (email) => api('/auth/login', { method: 'POST', body: JSON.stringify({ email, password: PW }) });

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

(async () => {
  const t = await login('teacher@wdf.test');
  const l = await login('learner@wdf.test');
  // Learners must have a photo; give the demo learner one via the API.
  const jpeg = Buffer.from('/9j/4AAQSkZJRgABAQEASABIAAD/2wBDAP' + 'A'.repeat(2000), 'base64');
  await fetch(A + '/me/photo', { method: 'POST', headers: { authorization: 'Bearer ' + l.token, 'content-type': 'application/octet-stream' }, body: jpeg });
  l.user = await api('/me', {}, l.token);
  const title = 'Mute test ' + Date.now();
  await api('/sessions', { method: 'POST', body: JSON.stringify({ subjectId: 's1', title, description: '', startsAt: new Date(Date.now() - 60000).toISOString(), minutes: 60 }) }, t.token);
  const id = (await api('/sessions', {}, t.token)).find((s) => s.title === title).id;
  const join = await api(`/sessions/${id}/join`, { method: 'POST' }, t.token); // admin token for checks
  const lk = join.url.replace(/^ws/, 'http');
  const learnerMic = async () => {
    const r = await (await fetch(`${lk}/twirp/livekit.RoomService/ListParticipants`, {
      method: 'POST', headers: { authorization: 'Bearer ' + join.token, 'content-type': 'application/json' },
      body: JSON.stringify({ room: 'class-' + id }),
    })).json();
    const p = (r.participants || []).find((x) => x.identity === 'l1');
    const mic = (p?.tracks || []).find((tr) => tr.source === 'MICROPHONE');
    const src = p?.permission?.canPublishSources ?? p?.permission?.can_publish_sources ?? [];
    return { published: !!mic && !mic.muted, allowed: !src.length || src.includes('MICROPHONE') || src.includes(2) };
  };
  const until = async (fn, ms = 10000) => { const end = Date.now() + ms; while (Date.now() < end) { if (await fn()) return; await new Promise((r) => setTimeout(r, 400)); } throw new Error('timed out'); };

  const browser = await chromium.launch({ channel: 'chrome', headless: true, args: ['--use-fake-ui-for-media-stream', '--use-fake-device-for-media-stream'] });
  const tp = await open(browser, { width: 1366, height: 820 }, false, t, id);
  const lp = await open(browser, { width: 412, height: 915 }, true, l, id);

  await step('Learner turns mic on', async () => {
    await lp.getByRole('button', { name: 'Mic' }).click();
    await until(async () => (await learnerMic()).published);
  });
  await step('Teacher taps "Mute all" -> learner mic goes off (server-side)', async () => {
    await tp.getByRole('button', { name: 'Mute all' }).click();
    await until(async () => !(await learnerMic()).published);
    const m = await learnerMic();
    if (m.allowed) throw new Error('mic still permitted');
  });
  await step('Learner sees the lock + unmute does NOT work', async () => {
    await lp.getByRole('button', { name: 'Muted' }).waitFor({ timeout: 8000 });
    await lp.getByRole('button', { name: 'Muted' }).click();
    await new Promise((r) => setTimeout(r, 3000));
    if ((await learnerMic()).published) throw new Error('learner managed to unmute');
  });
  await lp.screenshot({ path: __dirname + '/shots4/mute-learner-locked.png' });
  await step('Learner raises hand -> teacher "Let speak" -> learner mic comes ON', async () => {
    await lp.getByRole('button', { name: 'Hand' }).click();
    await tp.getByRole('button', { name: 'People' }).click();
    await tp.waitForTimeout(800);
    await tp.getByRole('button', { name: 'Show menu' }).first().click();
    await tp.getByRole('menuitem', { name: 'Let speak' }).click();
    await until(async () => (await learnerMic()).published, 12000);
  });
  await tp.screenshot({ path: __dirname + '/shots4/mute-teacher.png' });
  await step('Teacher mutes that learner again -> off and locked', async () => {
    await tp.getByRole('button', { name: 'Show menu' }).first().click();
    await tp.getByRole('menuitem', { name: 'Mute mic' }).click();
    await until(async () => !(await learnerMic()).published);
  });
  await step('Teacher taps "Unmute all" -> learner can use mic again', async () => {
    await tp.getByRole('button', { name: 'Unmute all' }).click();
    await lp.getByRole('button', { name: 'Mic' }).waitFor({ timeout: 8000 });
    await lp.getByRole('button', { name: 'Mic' }).click();
    await until(async () => (await learnerMic()).published);
  });
  await browser.close();
  await api(`/sessions/${id}`, { method: 'DELETE' }, t.token);
  console.log(results.join('\n'));
  console.log(errors.length ? 'PAGE ERRORS:\n' + [...new Set(errors)].join('\n') : 'No page errors.');
})();
