#!/usr/bin/env python3
import importlib.util
from pathlib import Path
import tempfile
import os
import subprocess
import hashlib
import json
ROOT=Path(__file__).resolve().parents[2]
spec=importlib.util.spec_from_file_location('release',ROOT/'openwrt/scripts/release-manifest.py')
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
with tempfile.TemporaryDirectory() as tmp:
    d=Path(tmp)
    pins=m.assignments(ROOT/'openwrt/versions.env')
    for package in m.PACKAGES:
        v=m.assignments(ROOT/package/'Makefile')
        names=[package]+(['luci-i18n-passwall-zh-cn'] if package=='luci-app-passwall' else [])
        for name in names: (d/f"{name}-{v['PKG_VERSION']}-r{v['PKG_RELEASE']}.apk").write_bytes(b'fixture')
    prefix=f"openwrt-{pins['OPENWRT_VERSION']}-x86-64-generic-"
    for fs in ('ext4','squashfs'):
        for efi in ('','-efi'): (d/f'{prefix}{fs}-combined{efi}.img.gz').write_bytes(b'image')
    for efi in ('','-efi'): (d/f'{prefix}ext4-combined{efi}.vmdk').write_bytes(b'vmware')
    for name in ('build-info.txt','packages.manifest'): (d/name).write_text('fixture')
    result=m.create(d);assert len(result['packages'])==4 and len(result['assets'])==12
    empty=d/result['packages'][0]['filename']; empty.write_bytes(b'')
    try: m.create(d)
    except ValueError: pass
    else: raise AssertionError('empty APK accepted')
    empty.write_bytes(b'fixture')
    target=d/result['packages'][1]['filename'];target.unlink()
    try: m.create(d)
    except ValueError: pass
    else: raise AssertionError('missing translation was accepted')
    target.write_bytes(b'fixture')
    (d/'luci-app-passwall-1.0.0-r1.apk').write_bytes(b'old')
    try: m.create(d)
    except ValueError: pass
    else: raise AssertionError('stale mixed release accepted')
    (d/'luci-app-passwall-1.0.0-r1.apk').unlink()
    subprocess.run(['python3',str(ROOT/'openwrt/scripts/release-manifest.py'),str(d)],check=True)
    (d/'SHA256SUMS').write_text(''.join(hashlib.sha256(p.read_bytes()).hexdigest()+'  '+p.name+'\n' for p in sorted(d.iterdir())))
    assert m.verify(d)['assets']==result['assets']
    original=(d/'SHA256SUMS').read_text()
    for broken in [original.split('\n',1)[1], original+original.splitlines()[0]+'\n', original+'0'*64+'  ../outside\n']:
        (d/'SHA256SUMS').write_text(broken)
        try: m.verify(d)
        except ValueError: pass
        else: raise AssertionError('incomplete or unsafe checksum inventory accepted')
    (d/'SHA256SUMS').write_text(original)
    (d/'unexpected.apk').write_bytes(b'extra')
    try: m.verify(d)
    except ValueError: pass
    else: raise AssertionError('unlisted artifact accepted')
    (d/'unexpected.apk').unlink()
    target=d/'build-info.txt'; target.write_text('tampered')
    # Even freshly recomputed checksums must not override the build manifest.
    (d/'SHA256SUMS').write_text(''.join(m.digest(p)+'  '+p.name+'\n' for p in sorted(d.iterdir()) if p.name!='SHA256SUMS'))
    try: m.verify(d)
    except ValueError: pass
    else: raise AssertionError('modified build manifest accepted')
    target.write_text('fixture'); (d/'SHA256SUMS').write_text(original)
    (d/'SHA256SUMS').rename(d/'saved-sums')
    (d/'SHA256SUMS').symlink_to('saved-sums')
    try: m.verify(d)
    except ValueError: pass
    else: raise AssertionError('symlink checksum file accepted')
    (d/'SHA256SUMS').unlink(); (d/'saved-sums').rename(d/'SHA256SUMS')
    bindir=Path(tmp)/'tools';bindir.mkdir()
    gh=bindir/'gh'
    gh.write_text("""#!/usr/bin/env python3
import os,sys,pathlib,shutil
args=sys.argv[1:]
with open(os.environ['GH_TEST_LOG'],'a') as f: f.write(' '.join(args[:2])+'\\n')
if args[1]=='view': sys.exit(1)
if args[1]=='download':
 dest=pathlib.Path(args[args.index('--dir')+1])
 for p in pathlib.Path(os.environ['GH_TEST_SOURCE']).iterdir():
  if p.is_file(): shutil.copy(p,dest/p.name)
 if os.environ.get('GH_TEST_CORRUPT')=='tamper': (dest/'build-info.txt').write_text('tampered')
 if os.environ.get('GH_TEST_CORRUPT')=='missing': (dest/'build-info.txt').unlink()
 if os.environ.get('GH_TEST_CORRUPT')=='extra': (dest/'unexpected.apk').write_text('extra')
""")
    gh.chmod(0o755)
    # Keep test executables outside the release artifact directory.
    tools=Path(tmp).parent/(Path(tmp).name+'-tools')
    bindir.rename(tools)
    try:
        log=tools/'calls'
        env=dict(os.environ,PATH=str(tools)+':'+os.environ['PATH'],GITHUB_REPOSITORY='test/repo',
                 GITHUB_REF_NAME='firmware-v'+pins['OPENWRT_VERSION']+'-r99',GH_TEST_SOURCE=str(d),GH_TEST_LOG=str(log))
        command=['bash',str(ROOT/'openwrt/scripts/publish-release.sh'),str(d)]
        for corrupt in ('tamper','missing','extra'):
            failed=subprocess.run(command,env=dict(env,GH_TEST_CORRUPT=corrupt),capture_output=True,text=True)
            assert failed.returncode and 'release create' in log.read_text() and 'release edit' not in log.read_text(),failed.stderr
            log.unlink()
        # A local omission must fail before creating any remote draft.
        (d/'SHA256SUMS').write_text(original.split('\n',1)[1])
        failed=subprocess.run(command,env=env,capture_output=True,text=True)
        assert failed.returncode and not log.exists(),failed.stderr
        (d/'SHA256SUMS').write_text(original)
        manifest_before=(d/'release-manifest.json').read_bytes()
        success=subprocess.run(command,env=env,capture_output=True,text=True)
        assert success.returncode==0,success.stderr
        assert (d/'release-manifest.json').read_bytes()==manifest_before
        assert log.read_text().splitlines()==['release view','release create','release download','release edit']
    finally:
        import shutil
        shutil.rmtree(tools)
assert not (ROOT/'.github/workflows/Auto compile with openwrt sdk.yml').exists()
publish=(ROOT/'openwrt/scripts/publish-release.sh').read_text()
assert publish.index('--draft \\') < publish.index('gh release download') < publish.index('--draft=false')
print('PASS immutable release manifest, exact inventory, empty/missing/tampered assets, symlinks and verified draft publication')
