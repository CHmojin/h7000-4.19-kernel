#!/usr/bin/env python3
"""Create/update a GitHub repo and push a directory tree via the contents API."""
import base64, json, os, sys, time, urllib.request, urllib.error

TOKEN = os.environ['GH_TOKEN']
OWNER = 'CHmojin'
REPO = sys.argv[1]
SRC = sys.argv[2]
DESC = sys.argv[3] if len(sys.argv) > 3 else ''
PRIVATE = os.environ.get('PRIVATE', 'false').lower() == 'true'
API = 'https://api.github.com'


def call(method, url, payload=None):
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(url, data=data, method=method, headers={
        'Authorization': 'token ' + TOKEN,
        'User-Agent': 'dsh-agent',
        'Accept': 'application/vnd.github+json',
        'Content-Type': 'application/json'})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return json.loads(r.read().decode() or '{}')
    except urllib.error.HTTPError as e:
        body = e.read().decode()
        if e.code == 404 and method == 'GET':
            return None
        raise SystemExit(f'{method} {url} -> {e.code} {body[:400]}')


repo = call('GET', f'{API}/repos/{OWNER}/{REPO}')
if not repo:
    repo = call('POST', f'{API}/user/repos',
                {'name': REPO, 'description': DESC, 'private': PRIVATE,
                 'has_issues': False, 'has_wiki': False, 'auto_init': False})
    print('created repo', repo['full_name'])
else:
    print('repo exists', repo['full_name'])
branch = repo.get('default_branch') or 'main'

skip_dirs = {'artifacts', '.git'}
pushed = 0
for root, dirs, files in os.walk(SRC):
    dirs[:] = [d for d in dirs if d not in skip_dirs]
    for f in files:
        path = os.path.join(root, f)
        rel = os.path.relpath(path, SRC).replace(os.sep, '/')
        if rel.startswith('artifacts/'):
            continue
        raw = open(path, 'rb').read()
        existing = call('GET', f'{API}/repos/{OWNER}/{REPO}/contents/{rel}')
        payload = {'message': f'update {rel}', 'content': base64.b64encode(raw).decode(),
                   'branch': branch}
        if existing and 'sha' in existing:
            if existing.get('size') == len(raw) and existing.get('sha'):
                pass
            payload['sha'] = existing['sha']
        call('PUT', f'{API}/repos/{OWNER}/{REPO}/contents/{rel}', payload)
        pushed += 1
        print(f'  {len(raw):8d}  {rel}')
        time.sleep(0.35)
print(f'pushed {pushed} files to {OWNER}/{REPO}@{branch}')
