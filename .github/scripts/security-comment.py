"""Publish sanitized scanner results to an associated PR or an actor-assigned main-branch issue."""
import json, os, pathlib, re, sys, time, urllib.error, urllib.request
e = os.environ
scanner = e['SCANNER']
assert re.fullmatch(r'[a-z0-9-]{1,50}', e['REPORT_PREFIX'])
assert scanner in ('trufflehog', 'bearer', 'govulncheck', 'trivy', 'trivy-infra')
url = f"{e['GITHUB_SERVER_URL']}/{e['GITHUB_REPOSITORY']}/actions/runs/{e['GITHUB_RUN_ID']}"
marker = f"<!-- security-report:{e['REPORT_PREFIX']}:{scanner}:{e['GITHUB_RUN_ID']} -->"
path = pathlib.Path('report.md')
report = path.read_text()[:50000] if path.is_file() else f"## {scanner} security report\n\nReport unavailable; scanner job: **{e['RESULT']}**. Check the run for setup or scanner errors."
report = report.replace('Scanner step: **success**.\n\n', '')
status = f"Job result: **{e['RESULT']}**. " if e['RESULT'] != 'success' else ''
body = f"{marker}\n{report}\n\n{status}[View workflow run]({url})\nCommit: `{e['GITHUB_SHA']}`"
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
    if '--initialize' not in sys.argv:
        comment(pr_number)
elif e.get('GITHUB_REF') == 'refs/heads/main':
    # Only PRs associated with this commit count; unrelated open PRs do not.
    prs = [pr for pr in items(f"/commits/{e['GITHUB_SHA']}/pulls")
           if pr['state'] == 'open' and
           (pr.get('head', {}).get('repo') or {}).get('full_name') == e['GITHUB_REPOSITORY']]
    if prs:
        if '--initialize' not in sys.argv:
            for pr in prs:
                comment(pr['number'])
    else:
        run_marker = f"<!-- security-run:{e['GITHUB_RUN_ID']} -->"
        selected = json.loads(e['INPUTS_JSON'])
        leader = next(s for s in ('trufflehog', 'bearer', 'govulncheck', 'trivy', 'trivy-infra') if selected[s])
        def find_issue():
            return next((i for i in items('/issues?state=all&creator=github-actions%5Bbot%5D')
                         if 'pull_request' not in i and
                         run_marker in (i.get('body') or '')), None)
        issue = find_issue()
        if not issue and scanner == leader:
            # One elected scanner creates the issue before scanning; peers only append
            # their own comments, avoiding concurrent issue-body overwrites.
            try:
                api('POST', '/labels', {'name': 'ci-security-findings', 'color': 'B60205',
                                      'description': 'CI security scanner reports'})
            except urllib.error.HTTPError as error:
                if error.code != 422:
                    raise
                api('GET', '/labels/ci-security-findings')
            issue = api('POST', '/issues', {
                'title': f"CI security findings — run {e['GITHUB_RUN_ID']}",
                'body': f"{run_marker}\nSecurity results from all scanners are published below as they finish.\n\n[View workflow run]({url})\nCommit: `{e['GITHUB_SHA']}`",
                'labels': ['ci-security-findings'], 'assignees': [e['GITHUB_ACTOR']]})
            if e['GITHUB_ACTOR'] not in [a['login'] for a in issue.get('assignees', [])]:
                raise RuntimeError('Report issue published, but GitHub did not assign it to the workflow actor.')
        if '--initialize' not in sys.argv:
            for attempt in range(60):
                if issue:
                    break
                time.sleep(5)
                issue = find_issue()
            if not issue:
                raise RuntimeError('Shared report issue unavailable; check the elected scanner initialization step.')
            comment(issue['number'])
