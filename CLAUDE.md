# WDF Classes — handoff for Claude (and Paida)

Live classes + assignments for WDF bursary learners. Built Sept 2026 with Nosipho (WDF developer /
COO, the product owner). **Paida takes over from here.** Server credentials are NOT in this repo —
Nosipho sends them separately. Never commit secrets (see "Secrets").

**Status: working and live, used as a pilot.** Web: https://learn.wdf.church · Android APK:
https://learn.wdf.church/wdf-classes.apk · Video server: wss://classes.wdf.church (self-hosted LiveKit).

## What it does
- **Learners**: sign in with a username + 6-digit password their graduate gave them → must add a
  selfie → see their classes (join live video), assignments (upload PDF/Word, see % + feedback),
  real-time alerts.
- **Teachers**: timetable CRUD (weekly repeats), run live classes (screen share on web, mute/remove,
  raise-hand, chat), post assignments with deadline + brief, extend deadlines (whole subject or one
  learner), mark in % with feedback, see attendance.
- **Graduates** (only *accepted Monarch* graduates = each church's "Head of Curriculum"): sign in
  with their **app.wdf.church login**, see their church's learners (pulled live from the WDF
  Tracker), enrol them (subjects pre-ticked from the bursary form), hand out logins (copy / Send on
  WhatsApp), reset passwords, get alerted when learners sign in. WDF graduates are refused.
- The church app (app.wdf.church, "Faith Hub") also shows a **WDF Classes box** on each student card
  for Monarch graduates (enrolled?, username/password, last sign-in).

## Architecture
```
Flutter app (web + Android)  ──HTTP/WebSocket──►  classes API (tool/dev_server.dart, compiled)
   learn.wdf.church                                  on Lightsail, /opt/wdf-classes, :8787
        │                                             │  data.json (all data) + uploads/
        │ LiveKit (WebRTC)                            │  reads (never writes) the WDF Tracker:
        ▼                                             ▼  app.wdf.church/api/graduate/{login,me,students}
LiveKit server (Docker) classes.wdf.church     WDF Tracker (Next.js+Prisma, Hostinger)
   same Lightsail box, /opt/livekit              app.wdf.church = church app (Flutter web) + /api/* → Tracker
```
- Everything live inside a class (chat, hands, mute/remove) goes over LiveKit, not the API.
- Real-time alerts outside class: WebSocket `/api/classes/ws` from the API.
- API contract: `wdf_classes/docs/API.md` (read it before changing endpoints).

## Repo layout
```
CLAUDE.md                     this file
wdf_classes/                  Flutter app (Flutter 3.41, Dart 3.11) — web + Android only
  lib/main.dart               router (go_router), role-based redirects, deferred classroom import
  lib/shell.dart              bottom bar (phone) / side rail (laptop) + live notification pop-ups
  lib/theme.dart              design tokens (Airbnb-style, scaled up: big text, 60px buttons)
  lib/api.dart  auth.dart  live.dart (WebSocket)  widgets.dart  format.dart
  lib/screens/                login, photo, timetable, class_form, classroom (LiveKit),
                              assignments, assignment (+ marking), assignment_form,
                              students (graduate), notifications, profile
  tool/dev_server.dart        THE backend (dev + prod). Single file, JSON-file persistence.
  docs/API.md                 endpoint contract
  docs/church-app-patch.py    the patch applied to app.wdf.church (see below)
  test/e2e/                   Playwright browser tests (real Chrome, phone + laptop sizes)
```

## Run locally
```bash
cd wdf_classes
flutter pub get
# API (+ serves the web build). Needs ../.env.livekit (LIVEKIT_URL/API_KEY/API_SECRET) — get from Nosipho.
WEB_DIR=build/web dart run tool/dev_server.dart          # http://localhost:8787
# optional: TRACKER_URL=https://app.wdf.church  (real graduate logins)  or the mock:
#   node test/e2e/mock-tracker.js  +  TRACKER_URL=http://localhost:8799
flutter build web --wasm --release                        # API_URL defaults to http://localhost:8787
```
Demo accounts (password `classes` locally; prod uses DEV_PASSWORD from the service unit):
`teacher@wdf.test`, `graduate@wdf.test`, `learner@wdf.test`, `learner2@wdf.test`.
Deleting `tool/dev_data.json` + `tool/uploads/` re-seeds the demo (subjects, classes, assignments,
a church roster of 8 learners). Server env: PORT, BIND, ENV_FILE, DATA_FILE, UPLOAD_DIR, WEB_DIR,
DEV_PASSWORD, TRACKER_URL, PUBLIC_URL.

## Tests
- `flutter analyze` must be clean.
- E2E (needs Chrome + `npm i` in test/e2e): `node assign.js` (photo gate, upload, real-time alerts,
  marking, extensions) and `node graduate.js` (enrol, generated login, sign-in alert). Point at prod
  with `WEB=https://learn.wdf.church PW=<demo password>`. **Run each on fresh data** (reset between),
  they change state. After testing prod, reset its data (stop service, delete data.json + uploads/, start).
- Flutter web testing tips: enable semantics by clicking `flt-semantics-placeholder`; type with a
  400 ms pause after focusing a field and ~40 ms per key (fast typing drops characters); Flutter
  merges a card's texts into one aria-label, so match text inside labels (see `find()` in the tests);
  SelectableText is not in the a11y tree.

## Deploy (Lightsail box "wdf-classroom", 63.185.61.37, user ubuntu, key from Nosipho)
```bash
cd wdf_classes
dart compile exe tool/dev_server.dart --target-os linux --target-arch x64 -o build/deploy/classes-api
flutter build web --wasm --release --dart-define=API_URL=https://learn.wdf.church -o build/web_prod
tar czf build/deploy/web.tgz -C build/web_prod .
# copy both to /tmp on the box, then as root:
#   systemctl stop wdf-classes; install -m755 /tmp/classes-api /opt/wdf-classes/classes-api
#   keep web/wdf-classes.apk!  rm -rf web/*; tar xzf /tmp/web.tgz -C web; put the apk back
#   systemctl start wdf-classes
flutter build apk --release --split-per-abi --target-platform android-arm64 --dart-define=API_URL=https://learn.wdf.church
#   → /opt/wdf-classes/web/wdf-classes.apk  (still signed with the DEBUG key — see open items)
```
- Service: `wdf-classes.service` (systemd), binary + `web/` + `data.json` (chmod 600) + `uploads/`
  in `/opt/wdf-classes`, binds 127.0.0.1:8787. Env vars live in the unit file.
- Caddy (LiveKit's `livekit/caddyl4` container, config `/opt/livekit/caddy.yaml`) terminates TLS by
  SNI: `classes.wdf.church` → LiveKit :7880, `turn.classes.wdf.church` → TURN :5349,
  `learn.wdf.church` → :8787. Restart: `docker restart livekit-caddy-1`.
- LiveKit: `/opt/livekit` (docker-compose: livekit-server v1.13.7 pinned, caddy, redis), systemd
  `livekit-docker`. API key/secret are in `/opt/livekit/livekit.yaml` and the app's `.env.livekit`.
- DNS (Cloudflare, **DNS only / grey cloud — never proxy**, UDP media breaks): `classes`,
  `turn.classes`, `learn` → 63.185.61.37. Lightsail firewall: 80, 443, 7881/tcp, 3478/udp,
  50000-60000/udp.

## The WDF Tracker & church app (Hostinger, 72.62.6.25) — LIVE SYSTEMS, be careful
- Tracker: `/root/wdf-tracker` (Next.js, Prisma, Postgres). We only **read** it via its existing
  graduate API. `/api/graduate/me` returns `{id, name, status, company, churchName, ...}` — the
  accepted company is `company`, and there is **no churchId** (we key Tracker churches as
  `tr_<churchName>`). `/api/graduate/students` only works for ACCEPTED+MONARCH graduates.
- Data facts (28 Sep 2026): 125 accepted Monarch graduates (all can sign in); 29 of them have no
  learners at their church; 22 churches (761 learners) have learners but no Head of Curriculum;
  ~10.4k Enrollment rows (4 compulsory modules + 1 skill each). Members log in by phone only in the
  church app; graduates have bcrypt passwords (unreadable — nobody can "get" a graduate's password).
- Church app = `/root/church_App/demo_app` (Flutter web), served by `wdf-app.service` on :3006.
  We patched `lib/services/api_client.dart` (`classesStudents()`) and
  `lib/screens/graduate/monarch_console_screen.dart` (`_classesBox` on each student card) — the
  patch script is `wdf_classes/docs/church-app-patch.py`. Build there:
  `flutter build web --release`, then add `?v=<sha1:12 of main.dart.js>` to `main.dart.js` in
  `build/web/flutter_bootstrap.js`, then `systemctl restart wdf-app.service`.
  **That repo has many uncommitted changes by others (incl. ours).** Backup of the pre-patch build:
  `/root/church_App/backups-wdf-classes-20260928-1145`. Always get Nosipho's OK before touching the
  Tracker or the church app.

## Gotchas (learned the hard way)
1. **After adding a Flutter plugin, run `flutter clean`** — a stale web plugin registrant gave
   `MissingPluginException` on web (image/file pickers, url_launcher) while analyze was clean.
2. **The server must handle requests concurrently** (`unawaited(serve(req))`). It used to await each
   request in the accept loop; one slow phone download froze every sign-in ("Can't reach the server").
3. Bottom sheets inside the tab shell need `useRootNavigator: true` or the tab bar covers them; and
   pop them with the sheet's own context.
4. `PageWidth` must give content a tight width (LayoutBuilder + SizedBox) or wide layouts collapse
   into a narrow centred column.
5. Seed data must be JSON round-tripped at startup, or typed map literals reject dynamic writes.
6. Learner passwords are stored in plain text on purpose (graduates must be able to see and resend
   them — Nosipho's decision). Treat `data.json` as sensitive.

## Secrets (never commit)
`.env.livekit`, `tool/dev_data.json`, `tool/uploads/`, server passwords/keys, the demo password.
`.gitignore` covers the files; check `git status` before every commit.

## Product decisions / preferences (from Nosipho)
- Flutter for web + Android; minimal and fast; **big elements** (Airbnb-style tokens in theme.dart,
  Rausch #FF385C accent); real-time wherever it matters.
- Only Monarch graduates onboard learners; learners get simple generated logins graduates can see.
- Marks are percentages; late work is accepted and flagged; extensions per learner or per subject.
- Explain changes in plain language; confirm before anything touching live WDF systems.

## Open items / next steps
- **Push notifications when the app is closed** (Firebase/FCM for Android, web push) — needs a
  Firebase project; in-app real-time alerts already work.
- **Enrolment dynamics**: subjects are auto-created from bursary-form names and all taught by the
  demo teacher `t1`. Needs real teachers (no TEACHER role exists in the Tracker yet) and **class
  groups** (e.g. 2,768 Baking learners can't be one live class — plan ~50–150 per group).
- Write enrolment back to the Tracker (the missing "enrolled" step) — only with Nosipho's OK.
- The backend is a single-file Dart server with JSON persistence: fine for the pilot, move to a
  real database before thousands of learners.
- Android release signing key (APK is debug-signed; updates may need uninstall first).
- Let learners change their own password later (graduates currently see all passwords).
- Security hygiene: the Lightsail SSH key and the Hostinger root password were pasted in chats —
  rotate both.
