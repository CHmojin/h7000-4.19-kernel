#!/usr/bin/env python3
"""Push a directory to a GitHub repo as ONE commit using the Git Data API.

Creating a single commit avoids triggering one workflow run per file.
"""
import base64, json, os, sys, urllib.request, urllib.error

TOKEN = os.environ['GH_TOKEN']
OWNER = 'CHmojin'
REPO = sys.argv[1]
SRC = sys.argv[2]
MESSAGE = sys.argv[3] if len(sys.argv) > 3 else 'update device overlay'
DESC = sys.argv[4] if len(sys.argv) > 4 else ''
PRIVATE = os.environ.get('PRIVATE', 'false').lower() == 'true'
API = 'https://api.github.com'


def call(method, url, payload=None):
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(url, data=data, method=method, headers={
        'Authorization': 'token ' + TOKEN, 'User-Agent': 'dsh-agent',
        'Accept': 'application/vnd.github+json', 'Content-Type': 'application/json'})
    try:
        with urllib.request.urlopen(req, timeout=90) as r:
            body = r.read().decode()
            return json.loads(body) if body.strip() else {}
    except urllib.error.HTTPError as e:
        detail = e.read().decode()[:500]
        if e.code == 404 and method == 'GET':
            return None
        raise SystemExit(f'{method} {url} -> {e.code} {detail}')


repo = call('GET', f'{API}/repos/{OWNER}/{REPO}')
if not repo:
    repo = call('POST', f'{API}/user/repos',
                {'name': REPO, 'description': DESC, 'private': PRIVATE,
                 'has_issues': False, 'has_wiki': False, 'auto_init': False})
    print('created repo', repo['full_name'])
branch = 'main'
ref = call('GET', f'{API}/repos/{OWNER}/{REPO}/git/ref/heads/{branch}')
parent = ref['object']['sha'] if ref else None
base_tree = None
if parent:
    base_tree = call('GET', f'{API}/repos/{OWNER}/{REPO}/git/commits/{parent}')['tree']['sha']

skip_dirs = {'artifacts', '.git'}
tree = []
for root, dirs, files in os.walk(SRC):
    dirs[:] = [d for d in dirs if d not in skip_dirs]
    for f in files:
        full = os.path.join(root, f)
        rel = os.path.relpath(full, SRC).replace(os.sep, '/')
        if rel.startswith('artifacts/'):
            continue
        raw = open(full, 'rb').read()
        blob = call('POST', f'{API}/repos/{OWNER}/{REPO}/git/blobs',
                    {'content': base64.b64encode(raw).decode(), 'encoding': 'base64'})
        tree.append({'path': rel, 'mode': '100644', 'type': 'blob', 'sha': blob['sha']})
        print(f'  blob {len(raw):8d}  {rel}')

if not tree:
    raise SystemExit('nothing to push')

payload = {'tree': tree}
if base_tree:
    payload['base_tree'] = base_tree
new_tree = call('POST', f'{API}/repos/{OWNER}/{REPO}/git/trees', payload)
commit_payload = {'message': MESSAGE, 'tree': new_tree['sha']}
if parent:
    commit_payload['parents'] = [parent]
commit = call('POST', f'{API}/repos/{OWNER}/{REPO}/git/commits', commit_payload)
if parent:
    call('PATCH', f'{API}/repos/{OWNER}/{REPO}/git/refs/heads/{branch}',
         {'sha': commit['sha'], 'force': False})
else:
    call('POST', f'{API}/repos/{OWNER}/{REPO}/git/refs',
         {'ref': f'refs/heads/{branch}', 'sha': commit['sha']})
print(f'pushed {len(tree)} files as commit {commit["sha"][:12]} on {OWNER}/{REPO}@{branch}')
