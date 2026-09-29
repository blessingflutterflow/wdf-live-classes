# WDF Classes API

Base: `API_URL/api/classes` (prod: `https://learn.wdf.church/api/classes`).
Implemented by `tool/dev_server.dart` — a single-file Dart server that is BOTH the
local dev server and what runs in production today (compiled to a Linux binary).
Long-term the plan was for the WDF Tracker to own this API; this file is the contract.

JSON everywhere. Auth: `Authorization: Bearer <token>` (token from `/auth/login`).
Errors: 4xx/5xx with `{"error": "Human-readable message"}` — the app shows it as-is.
Uploads: raw bytes, `content-type: application/octet-stream`, filename in `x-filename` (URI-encoded).

## Roles
| role | who | signs in with |
|---|---|---|
| `teacher` | runs classes, posts & marks assignments | demo email (`teacher@wdf.test`) |
| `graduate` | accepted Monarch graduate (church "Head of Curriculum") or accepted WDF graduate; enrols learners | **their app.wdf.church (Tracker) login** — checked live against the Tracker; or demo `graduate@wdf.test` |
| `learner` | attends, submits, sees marks | username (firstname+4 digits) + 6-digit password generated when a graduate enrols them |

Demo emails use one shared password (`DEV_PASSWORD` env; `classes` locally).

## Auth / profile
- `POST /auth/login` `{email, password}` — `email` may be an email, a learner username, or a cell number.
  Order: local user (email/username) → otherwise, if `TRACKER_URL` is set, Tracker graduate login
  (`/api/graduate/login` then `/api/graduate/me`; any graduate, whatever their status).
  → `{token, user: {id, name, role, company?, photo}}`. Learners not yet enrolled get 403.
- `GET /me` → user
- `POST /me/photo` (raw JPEG) → user. Learners must have a photo before using the app.

## Subjects
- `GET /subjects` → `[{id, name, teacherName, learnerCount?}]` (teacher/co-teacher: theirs + count; learner: enrolled; graduate: all)

## Classes (sessions)
Session: `{id, subjectId, subjectName, title, description, teacherId, teacherName, startsAt, minutes}`
- `GET /sessions` (last 24h onwards, only subjects you're in) · `GET /sessions/:id`
- `POST /sessions` (teacher of subject) `{subjectId, title, description, startsAt, minutes, repeatWeeks}`
- `PUT /sessions/:id` · `DELETE /sessions/:id` (owning teacher)
- `GET /sessions/:id/attendance` → users
- `POST /sessions/:id/join` → `{url, token}` LiveKit token. Learners: 15 min before start → end.

## Assignments
Assignment: `{id, subjectId, subjectName, title, instructions, dueAt, briefName, briefUrl,
  learnerCount, submittedCount, markedCount   // teacher
  mine: Submission                           // learner
  submissions: [Submission]                  // teacher, detail only}`
Submission: `{learner, dueAt (incl. extension), extended, fileName, fileUrl, submittedAt, late, percent, feedback, markedAt}`
- `GET /assignments` · `GET /assignments/:id`
- `POST /assignments` → created; then `POST /:id/brief` (raw file, optional); then `POST /:id/publish` (notifies learners)
- `PUT /assignments/:id` `{title, instructions}` · `DELETE /assignments/:id`
- `POST /assignments/:id/submit` (learner, raw PDF/DOC/DOCX ≤ 20 MB; replaces previous; `late` if after THEIR due date)
- `POST /assignments/:id/extend` `{dueAt, learnerId?}` — no learnerId = whole subject
- `POST /assignments/:id/mark` `{learnerId, percent 0-100, feedback}`
- Files: `GET /files/<key>?exp=&sig=` — signed, expiring links (no auth header so they open in a tab).

## Graduates: enrolment
- `GET /students` → the graduate's church roster (churches keyed `tr_<churchName>`). Monarch graduates
  first sync from Tracker `/api/graduate/students` (learner ids `m_<memberId>` or `e_<enrollmentId>`);
  Everyone else (WDF, not yet approved) gets the list as last synced by a Monarch graduate (may be empty).
- `POST /students` `{name, cell, skill, modules?}` — graduate adds a learner by hand (not in the Tracker);
  validates name+surname and a 10-digit SA cell, refuses a duplicate cell at the church, enrols at once.
  Each: `{...user, cell, modules, skill, enrolled, username, password, lastLoginAt, subjectIds, formSubjectIds}`
- `POST /students/:id/enrol` `{subjectIds}` — creates username/password on first enrol; `[]` = unenrol
- `POST /students/enrol-all` — every not-enrolled learner into their form subjects
- `POST /students/:id/reset-password` — new password, signs the learner out everywhere
- Learner sign-in → graduate notification (first time always, then max once/day).

## Church app bridge
- `GET /tracker/students` with `Authorization: Bearer <TRACKER graduate token>` (NOT a classes token).
  Validates via Tracker `/api/graduate/me`, syncs roster, returns
  `{classesUrl, students: [{key, enrolled, username, password, lastLoginAt}]}`.
  Used by app.wdf.church (Faith Hub) to show the "WDF Classes" box on each student card.

## Notifications & real time
- `GET /notifications` · `POST /notifications/read` `{ids?}` (none = all)
- WebSocket `GET /ws?token=<classes token>` — server pushes
  `{"type":"notification","topic":..., "notification":{...}}` and `{"type":"changed","topic":"sessions|assignments|students"}`.
- Server timer (30 s): "class starts in 15 min" and "assignment due in 24 h" reminders.

## Inside a live class (LiveKit, no backend)
- Chat: data packet topic `chat` `{"text"}` · Raise hand: participant attribute `hand="1"`
- Teacher lowers a hand: data packet topic `cmd` `{"cmd":"lower_hand"}`
- Teacher mute/remove: LiveKit RoomService Twirp called directly with the teacher's join token
  (it has `roomAdmin` for that one room only).
- Token attributes: `{role, photo}`.
