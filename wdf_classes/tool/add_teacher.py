"""Add (or update) a teacher who co-teaches every subject. Run ONLY while the server is stopped.

Usage: python3 tool/add_teacher.py <data.json> <id> "<Full Name>" <username> <password>
Signs in with the username + password. Safe to run twice.
"""
import json, sys

path, uid, name, username, password = sys.argv[1:6]
with open(path, encoding='utf-8') as f:
    db = json.load(f)
users = db['users']
if any(u.get('username') == username.lower() and u['id'] != uid for u in users):
    sys.exit(f'username {username} is already taken')
u = next((u for u in users if u['id'] == uid), None)
if u is None:
    u = {'id': uid}
    users.append(u)
u.update({'name': name, 'role': 'teacher', 'username': username.lower(), 'password': password})
for s in db['subjects']:
    ids = s.setdefault('teacherIds', [])
    if uid not in ids:
        ids.append(uid)
tmp = path + '.tmp'
with open(tmp, 'w', encoding='utf-8') as f:
    json.dump(db, f)
import os
os.replace(tmp, path)
print(f'{name} ({username}) teaches all {len(db["subjects"])} subjects')
