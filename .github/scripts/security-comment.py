"""Publish sanitized scanner results to an associated PR or an actor-assigned main-branch issue."""
import json, os, pathlib, re, urllib.request
e = os.environ
scanner = e['SCANNER']
assert re.fullmatch(r'[a-z0-9-]{1,50}', e['REPORT_PREFIX'])
assert scanner in ('trufflehog', 'bearer', 'govulncheck', 'trivy', 'trivy-infra')
url = f"{e['GITHUB_SERVER_URL']}/{e['GITHUB_REPOSITORY']}/actions/runs/{e['GITHUB_RUN_ID']}"
marker = f"<!-- security-report:{e['REPORT_PREFIX']}:{scanner}:{e['GITHUB_RUN_ID']} -->"
path = pathlib.Path('report.md')
report = path.read_text()[:50000] if path.is_file() else f"## {scanner} security report\n\nReport unavailable; scanner job: **{e['RESULT']}**. Check the run for setup or scanner errors."
body = f"{marker}\n{report}\n\nJob result: **{e['RESULT']}**. [View workflow run]({url})\nCommit: `{e['GITHUB_SHA']}`"
base = f"{e['GITHUB_API_URL']}/repos/{e['GITHUB_REPOSITORY']}"
def api(method, endpoint, data=None):
    request = urllib.request.Request(base + endpoint, method=method,
        data=json.dumps(data).encode() if data is not None else None,
        headers={'Authorization': 'Bearer ' + e['GH_TOKEN'],
                 'Accept': 'application/vnd.github+json', 'Content-Type': 'application/json'})
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)
def items(endpoint):
    page = 1
    while True:
        separator = '&' if '?' in endpoint else '?'
        batch = api('GET', endpoint + f'{separator}per_page=100&page={page}')
        yield from batch
        if len(batch) < 100:
            break
        page += 1


def owned_report(item):
    return item['user']['login'] == 'github-actions[bot]' and marker in (item.get('body') or '')


def comment(number):
    endpoint = f'/issues/{number}/comments'
    existing = next((c for c in items(endpoint) if owned_report(c)), None)
    if existing:
        api('PATCH', f"/issues/comments/{existing['id']}", {'body': body})
    else:
        api('POST', endpoint, {'body': body})


pr_number = e.get('PR_NUMBER', '')
if pr_number:
    assert pr_number.isdigit()
    comment(pr_number)
elif e.get('GITHUB_REF') == 'refs/heads/main':
    # Only PRs associated with this commit count; unrelated open PRs do not.
    prs = [pr for pr in items(f"/commits/{e['GITHUB_SHA']}/pulls")
           if pr['state'] == 'open' and
           (pr.get('head', {}).get('repo') or {}).get('full_name') == e['GITHUB_REPOSITORY']]
    if prs:
        for pr in prs:
            comment(pr['number'])
    else:
        existing = next((i for i in items('/issues?state=all&creator=github-actions%5Bbot%5D')
                         if 'pull_request' not in i and owned_report(i)), None)
        payload = {'title': f"Security report: {e['REPORT_PREFIX']} / {scanner} — {e['RESULT']} (run {e['GITHUB_RUN_ID']})",
                   'body': body, 'assignees': [e['GITHUB_ACTOR']]}
        if existing:
            issue = api('PATCH', f"/issues/{existing['number']}", payload)
        else:
            issue = api('POST', '/issues', payload)
        if e['GITHUB_ACTOR'] not in [a['login'] for a in issue.get('assignees', [])]:
            raise RuntimeError('Report issue published, but GitHub did not assign it to the workflow actor; check repository assignment permissions.')
