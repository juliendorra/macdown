#!/usr/bin/env python3
"""Scan working source, submodules, Git history, or a packaged app with Gitleaks."""
import argparse
import hashlib
import io
from pathlib import Path
import platform
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request

ROOT = Path(__file__).resolve().parent.parent
VERSION = '8.30.1'
# SHA256 values from the official release's checksums, verified during the audit.
CHECKSUMS = {
    ('Darwin', 'arm64'): 'b40ab0ae55c505963e365f271a8d3846efbc170aa17f2607f13df610a9aeb6a5',
    ('Darwin', 'x64'): 'dfe101a4db2255fc85120ac7f3d25e4342c3c20cf749f2c20a18081af1952709',
    ('Linux', 'arm64'): 'e4a487ee7ccd7d3a7f7ec08657610aa3606637dab924210b3aee62570fb4b080',
    ('Linux', 'x64'): '551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb',
}


def run(*command):
    subprocess.run(command, cwd=ROOT, check=True)


def tool():
    cached = ROOT / '.build/test-tools/gitleaks'
    for candidate in [cached, ROOT / '.build/security-tools/gitleaks/gitleaks']:
        if candidate.is_file() and subprocess.check_output([str(candidate), 'version'], text=True).strip() == VERSION:
            return str(candidate)
    architecture = {'aarch64': 'arm64', 'amd64': 'x64', 'x86_64': 'x64'}.get(platform.machine().lower(), platform.machine().lower())
    key = (platform.system(), architecture)
    if key not in CHECKSUMS:
        raise RuntimeError(f'No pinned Gitleaks binary for {key}')
    name = f'gitleaks_{VERSION}_{key[0].lower()}_{architecture}.tar.gz'
    url = f'https://github.com/gitleaks/gitleaks/releases/download/v{VERSION}/{name}'
    request = urllib.request.Request(url, headers={'User-Agent': 'MacDown-tests'})
    with urllib.request.urlopen(request, timeout=60) as response:
        archive = response.read()
    if hashlib.sha256(archive).hexdigest() != CHECKSUMS[key]:
        raise RuntimeError('Gitleaks download checksum does not match the pinned release')
    cached.parent.mkdir(parents=True, exist_ok=True)
    with tarfile.open(fileobj=io.BytesIO(archive), mode='r:gz') as source:
        member = source.getmember('gitleaks')
        if not member.isfile():
            raise RuntimeError('Gitleaks archive has no regular executable')
        cached.write_bytes(source.extractfile(member).read())
    cached.chmod(0o755)
    if subprocess.check_output([str(cached), 'version'], text=True).strip() != VERSION:
        raise RuntimeError('Unexpected Gitleaks version')
    return str(cached)


def scan(binary, output, mode, target, *extra):
    run(binary, mode, str(target), '--redact=100', '--ignore-gitleaks-allow',
        '--gitleaks-ignore-path', str(ROOT / '.gitleaksignore'), '--no-banner',
        '--report-format', 'json', '--report-path', str(output), *extra)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--app', type=Path, help='Scan only this app, without source/history scans')
    args = parser.parse_args()
    args.output = args.output.resolve()
    args.output.mkdir(parents=True, exist_ok=True)
    binary = tool()
    if args.app:
        if not args.app.is_dir():
            raise RuntimeError('Packaged app not found')
        scan(binary, args.output / 'app.json', 'dir', args.app.resolve())
        return
    shallow = subprocess.check_output(['git', 'rev-parse', '--is-shallow-repository'], cwd=ROOT, text=True).strip()
    if shallow == 'true':
        raise RuntimeError('Secret history checks require full history: git fetch --unshallow')
    tracked = subprocess.check_output(['git', 'ls-files', '--cached', '--recurse-submodules', '-z'], cwd=ROOT)
    untracked = subprocess.check_output(['git', 'ls-files', '--others', '--exclude-standard', '-z'], cwd=ROOT)
    # Scan actual file contents, including uncommitted edits, not a binary tar stream.
    with tempfile.TemporaryDirectory(prefix='macdown-secret-source-') as temporary:
        tree = Path(temporary)
        for relative in set((tracked + untracked).split(b'\0')) - {b''}:
            path = ROOT / relative.decode('utf-8')
            if not path.is_file():
                continue
            if not path.resolve().is_relative_to(ROOT):
                raise RuntimeError(f'Tracked symlink escapes the repository: {relative!r}')
            destination = tree / relative.decode('utf-8')
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(path, destination)
        scan(binary, args.output / 'source.json', 'dir', tree)
    scan(binary, args.output / 'history.json', 'git', ROOT,
         '--log-opts=--all --full-history --diff-merges=first-parent')


if __name__ == '__main__':
    main()
