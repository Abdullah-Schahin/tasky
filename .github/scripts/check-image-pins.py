"""Require literal SHA256 pins for all external Dockerfile base images."""
from pathlib import Path
import re
import sys


def check(path):
    stages = set()
    errors = []
    source = Path(path).read_text().replace("\\\n", " ")
    for line in source.splitlines():
        parts = line.split()
        if not parts or parts[0].upper() != 'FROM':
            continue
        args = parts[1:]
        while args and args[0].startswith('--'):
            args.pop(0)
        if not args:
            errors.append(f'{path}: missing FROM image')
            continue
        image = args[0]
        if image.lower() not in stages and image != 'scratch':
            if not re.fullmatch(r'[^\s@$]+@sha256:[0-9a-f]{64}', image):
                errors.append(f'{path}: external base image must use a literal @sha256 digest: {image}')
        if len(args) >= 3 and args[1].upper() == 'AS':
            stages.add(args[2].lower())
    return errors


if __name__ == '__main__':
    errors = [error for path in (sys.argv[1:] or ['Dockerfile']) for error in check(path)]
    for error in errors:
        print(error, file=sys.stderr)
    sys.exit(bool(errors))
