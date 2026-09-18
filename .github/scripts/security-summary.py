"""Build bounded scanner summaries; never copy secret values or source snippets."""
import html
import json
import os
from pathlib import Path
import sys


def objects(text):
    decoder = json.JSONDecoder()
    while text.strip():
        item, end = decoder.raw_decode(text.lstrip())
        yield item
        text = text.lstrip()[end:]


def cell(value):
    text = html.escape(str(value)[:300]).replace('|', '&#124;').replace('\n', ' ').replace('@', '&#64;').replace('`', '&#96;')
    for char in ('\\', '[', ']', '(', ')', '!', '*', '_'):
        text = text.replace(char, '\\' + char)
    return text


def details(scanner, text):
    rows = []
    if scanner == 'trufflehog':
        for finding in objects(text):
            git = finding.get('SourceMetadata', {}).get('Data', {}).get('Git', {})
            # Explicit allowlist: omit Raw, RawV2, Redacted, ExtraData and all messages.
            rows.append((finding.get('DetectorName', 'Unknown detector'),
                         'verified' if finding.get('Verified') else 'unknown',
                         f"{git.get('file', '?')}:{git.get('line', '?')}"))
    elif scanner in ('bearer', 'trivy'):
        for run in json.loads(text).get('runs', []):
            for result in run.get('results', []):
                loc = (result.get('locations') or [{}])[0].get('physicalLocation', {})
                rows.append((result.get('ruleId', 'unknown'), result.get('level', 'warning'),
                             f"{loc.get('artifactLocation', {}).get('uri', '?')}:{loc.get('region', {}).get('startLine', '?')}"))
    else:
        for obj in objects(text):
            if 'finding' in obj:
                finding = obj['finding']
                trace = (finding.get('trace') or [{}])[0]
                position = trace.get('position', {})
                rows.append((finding.get('osv', '?'),
                             'reachable' if trace.get('function') else 'module/package match',
                             f"{trace.get('module', '?')} {trace.get('version', '')} {position.get('filename', '')}:{position.get('line', '')}"))
    return list(dict.fromkeys(rows))


def main():
    scanner, source, destination = sys.argv[1:]
    outcome = os.environ.get('SCAN_OUTCOME', 'unknown')
    body = f'## {scanner} security report\n\nScanner step: **{cell(outcome)}**.\n\n'
    try:
        rows = details(scanner, Path(source).read_text())
        body += f'{len(rows)} finding(s) reported.\n\n'
        if rows:
            body += '| Rule / detector | Classification | Location / module |\n| --- | --- | --- |\n'
            body += ''.join('| ' + ' | '.join(map(cell, row)) + ' |\n' for row in rows[:50])
            if len(rows) > 50:
                body += '\nOnly the first 50 findings are shown.\n'
    except (OSError, ValueError, TypeError, AttributeError):
        body += 'No readable scanner report was produced. Check the scanner/setup step for execution errors.\n'
    if scanner == 'trufflehog':
        code = os.environ.get('SCAN_EXIT_CODE', '')
        if code == '183':
            body += '\n**Blocked:** potential secrets detected. Review the locations and rotate/revoke any exposed credentials.\n'
        elif outcome == 'failure':
            body += '\n**Blocked:** scanner execution failed. Inspect the run and rerun after resolving the error.\n'
        body += '\nSecret values and source snippets are intentionally omitted.\n'
    if scanner == 'bearer':
        body += '\nBearer findings remain advisory for this exercise (exit-code 0).\n'
    if scanner == 'govulncheck':
        body += '\nModule/package matches are informational; reachable vulnerabilities block CI.\n'
    if outcome == 'failure' and scanner != 'trufflehog':
        body += '\n**Blocked:** the scanner failed; review findings and scanner errors in the run.\n'
    Path(destination).write_text(body)
    with open(os.environ.get('GITHUB_STEP_SUMMARY', os.devnull), 'a') as summary:
        summary.write(body)


if __name__ == '__main__':
    main()
