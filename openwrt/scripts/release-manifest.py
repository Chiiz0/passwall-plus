#!/usr/bin/env python3
"""Validate a complete dedicated release and record its exact build inputs."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
PACKAGES = ('luci-app-passwall', 'luci-app-passwall-ezcnet', 'luci-theme-ezwrt')

def digest(path):
    result = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            result.update(chunk)
    return result.hexdigest()

def assignments(path):
    return dict(re.findall(r'^([A-Z_]+)(?::=|=)(.*)$', path.read_text(), re.M))

def create(directory, root=ROOT):
    pins = assignments(root / 'openwrt/versions.env')
    packages = []
    for name in PACKAGES:
        values = assignments(root / name / 'Makefile')
        version = f"{values['PKG_VERSION']}-r{values['PKG_RELEASE']}"
        names = [name]
        if name == 'luci-app-passwall':
            names.append('luci-i18n-passwall-zh-cn')
        for package in names:
            filename = f'{package}-{version}.apk'
            if sorted(p.name for p in directory.glob(f'{package}-[0-9]*.apk')) != [filename]:
                raise ValueError(f'missing, duplicate or wrong version package: {package}')
            packages.append({'name': package, 'version': version, 'filename': filename})
    prefix = f"openwrt-{pins['OPENWRT_VERSION']}-{pins['OPENWRT_TARGET']}-{pins['OPENWRT_SUBTARGET']}-generic-"
    required = [prefix + fs + '-combined' + efi + '.img.gz'
                for fs in ('ext4', 'squashfs') for efi in ('', '-efi')]
    required += [prefix + 'ext4-combined' + efi + '.vmdk' for efi in ('', '-efi')]
    required += ['build-info.txt', 'packages.manifest']
    required += [package['filename'] for package in packages]
    for filename in required:
        if not (directory / filename).is_file() or not (directory / filename).stat().st_size:
            raise ValueError(f'missing or empty release artifact: {filename}')
    assets = {}
    for path in sorted(directory.iterdir()):
        if not path.is_file() or path.is_symlink() or not re.fullmatch(r'[A-Za-z0-9._+-]+', path.name):
            raise ValueError(f'invalid release asset: {path.name}')
        if path.name in ('SHA256SUMS', 'release-manifest.json'):
            continue
        assets[path.name] = {'size': path.stat().st_size, 'sha256': digest(path)}
    return {'schema': 1, 'channel': 'stable', 'package_format': 'apk',
            'openwrt': pins['OPENWRT_VERSION'], 'architecture': pins['OPENWRT_ARCH'],
            'kernel': pins['OPENWRT_KERNEL'], 'pins': pins, 'packages': packages, 'assets': assets}

def verify(directory, root=ROOT):
    # Validate the recorded build, never regenerate its provenance at publish time.
    expected = create(directory, root)
    manifest = json.loads((directory / 'release-manifest.json').read_text())
    if not isinstance(manifest, dict) or any(manifest.get(key) != value for key, value in expected.items()):
        raise ValueError('release manifest does not match the artifacts or pinned versions')
    if not re.fullmatch(r'[0-9a-f]{40,64}', str(manifest.get('source_commit', ''))) or type(manifest.get('source_dirty')) is not bool:
        raise ValueError('invalid source provenance')
    checksums = {}
    for line in (directory / 'SHA256SUMS').read_text().splitlines():
        match = re.fullmatch(r'([0-9a-f]{64}) [ *]([A-Za-z0-9._+-]+)', line)
        if not match or match[2] in checksums:
            raise ValueError('invalid or duplicate checksum entry')
        checksums[match[2]] = match[1]
    wanted = {name: asset['sha256'] for name, asset in expected['assets'].items()}
    wanted['release-manifest.json'] = digest(directory / 'release-manifest.json')
    if checksums != wanted:
        raise ValueError('checksum inventory or digest mismatch')
    return manifest

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    parser.add_argument('--verify', action='store_true', help='verify an existing manifest and exact checksum inventory')
    args = parser.parse_args()
    try:
        if args.verify:
            verify(args.directory)
        else:
            manifest = create(args.directory)
            manifest['source_commit'] = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
            manifest['source_dirty'] = bool(subprocess.check_output(['git', 'status', '--porcelain', '--untracked-files=normal'], cwd=ROOT))
            (args.directory / 'release-manifest.json').write_text(json.dumps(manifest, indent=2, sort_keys=True) + '\n')
    except (OSError, ValueError) as error:
        sys.exit(f'Release validation failed: {error}')
