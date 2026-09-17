"""Format hook inputs, restaging only changed files already fully staged on entry."""
import subprocess
import sys
from pathlib import Path


def main():
    args = sys.argv[1:]
    fix_exit_one = args[0] == '--fix-exit-one'
    if fix_exit_one:
        args.pop(0)
    split = args.index('--')
    command, files = args[:split], args[split + 1:]
    if not files:
        return 0
    staged = set(subprocess.check_output(
        ['git', 'diff', '--cached', '--name-only', '-z', '--diff-filter=ACMR'],
    ).decode().split('\0'))
    before = {name: Path(name).read_bytes() for name in files}
    eligible = [name for name in files if name in staged and subprocess.run(
        ['git', 'diff', '--quiet', '--', name], check=False,
    ).returncode == 0]
    result = subprocess.run([*command, *files], check=False)
    changed = [name for name in files if Path(name).read_bytes() != before[name]]
    if result.returncode != 0 and not (fix_exit_one and result.returncode == 1 and changed):
        return result.returncode
    restage = [name for name in changed if name in eligible]
    if restage:
        subprocess.run(['git', 'add', '--', *restage], check=True)
    return 0


if __name__ == '__main__':
    sys.exit(main())
