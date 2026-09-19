"""Exclude two reviewed historical documentation placeholders, never verified secrets."""
import hashlib
import json
from pathlib import Path
import sys

# Exact SHA256 of the detector's Raw value, scoped to detector and source file.
# These were USER/URL_ENCODED_PASSWORD and username/password examples removed
# from the documentation; history scans continue to encounter their old commits.
EXAMPLES = {
    'infra/helm/README.md': '0a71b8abd0a54e5cc8050934084453f0841dffae48fc1fbbe91290c6dc7fe401',
    'README.md': 'b3a5384a8b2b1661fb082a48a3b7f9368ac359ecd3f2d53146e876b0d43daf3c',
}


def is_example(finding):
    source = finding.get('SourceMetadata', {}).get('Data', {}).get('Git', {})
    raw = finding.get('Raw')
    return (finding.get('DetectorName') == 'MongoDB'
            and finding.get('Verified') is False
            and isinstance(raw, str)
            and hashlib.sha256(raw.encode()).hexdigest() == EXAMPLES.get(source.get('file')))


def main():
    path, code = Path(sys.argv[1]), int(sys.argv[2])
    # Preserve all scanner execution errors, including missing/malformed output.
    if code not in (0, 183):
        return code
    findings = [json.loads(line) for line in path.read_text().splitlines() if line.strip()]
    remaining = [f for f in findings if not is_example(f)]
    path.write_text(''.join(json.dumps(f) + '\n' for f in remaining))
    print(f'Excluded {len(findings) - len(remaining)} reviewed historical documentation placeholder(s).')
    return 183 if remaining else 0


if __name__ == '__main__':
    sys.exit(main())
