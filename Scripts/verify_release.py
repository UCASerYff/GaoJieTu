#!/usr/bin/env python3
"""Verify release provenance without launching the application or reading user data."""
import argparse, hashlib, json, pathlib, plistlib, re, stat, subprocess, zipfile

def require(value, message):
    if not value:
        raise RuntimeError(message)

def sha(data):
    return hashlib.sha256(data).hexdigest()

def archive(path):
    result = {}
    with zipfile.ZipFile(path, metadata_encoding='utf-8') as source:
        for entry in source.infolist():
            parts = entry.filename.split('/')
            require(not entry.filename.startswith('/') and not any(p in ('.', '..') for p in parts), 'unsafe archive path')
            if entry.is_dir():
                continue
            require(entry.filename not in result, 'duplicate archive path')
            require(stat.S_IFMT(entry.external_attr >> 16) != stat.S_IFLNK, 'archive contains a symlink')
            result[entry.filename] = source.read(entry)
    require(result, 'archive contains no files')
    return result

def verify(app_zip, source_zip, checksum_file, commit, installed=None):
    commit = subprocess.check_output(['git', 'rev-parse', commit], text=True).strip()
    source = archive(source_zip)
    tree = subprocess.check_output(['git', 'ls-tree', '-rz', '--full-tree', commit]).split(b'\0')
    expected = {}
    for entry in tree:
        if not entry:
            continue
        mode_type_hash, name = entry.split(b'\t', 1)
        mode, kind, object_hash = mode_type_hash.decode().split()
        require(mode in ('100644', '100755') and kind == 'blob', 'source contains an unsupported object')
        expected[name.decode()] = object_hash
    require(set(source) == set(expected), 'source archive is not the complete selected commit')
    for name, data in source.items():
        require(name.split('/')[0] not in {'.git', '.build', '.build.noindex', 'TestResults', 'Release', 'Backups', 'private'}, 'private/build data in source archive')
        blob = subprocess.check_output(['git', 'cat-file', 'blob', expected[name]])
        require(data == blob, 'source bytes differ from selected commit: ' + name)
    packaged = archive(app_zip)
    prefix = '搞截图.app/'
    require(all(name.startswith(prefix) for name in packaged), 'application archive contains unrelated files')
    app = {name[len(prefix):]: data for name, data in packaged.items()}
    allowed = {'Contents/Info.plist', 'Contents/MacOS/GaoJieTu', 'Contents/Resources/AppIcon.icns',
               'Contents/Resources/GaoCapabilities.json', 'Contents/Resources/BuildInfo.json', 'Contents/_CodeSignature/CodeResources'}
    require(set(app) == allowed, 'application contains unexpected or missing files')
    info = plistlib.loads(app['Contents/Info.plist'])
    source_info = plistlib.loads(source['Resources/Info.plist'])
    keys = ('CFBundleIdentifier', 'CFBundleShortVersionString', 'CFBundleVersion', 'CFBundleExecutable')
    require(all(info.get(key) == source_info.get(key) for key in keys), 'application/source version or identity mismatch')
    require(info['CFBundleIdentifier'] == 'com.gaoseries.GaoJieTu', 'wrong application')
    require(app['Contents/Resources/GaoCapabilities.json'] == source['Resources/GaoCapabilities.json'], 'capabilities differ from source commit')
    capabilities = json.loads(app['Contents/Resources/GaoCapabilities.json'])
    require(app['Contents/Resources/AppIcon.icns'] == source['Assets/AppIcon.icns'], 'application icon differs from source commit')
    require(capabilities['appVersion'] == info['CFBundleShortVersionString'], 'capability version mismatch')
    provenance = json.loads(app['Contents/Resources/BuildInfo.json'])
    require(provenance['sourceCommit'] == commit and provenance['sourceDirty'] is False, 'build is not from the selected clean commit')
    require(provenance['version'] == info['CFBundleShortVersionString'] and str(provenance['build']) == info['CFBundleVersion'], 'build provenance version mismatch')
    checksums = {}
    for line in checksum_file.read_text().splitlines():
        digest, name = line.split(maxsplit=1)
        name = pathlib.Path(name.lstrip('*')).name
        require(re.fullmatch('[0-9a-f]{64}', digest) is not None and name not in checksums, 'invalid/duplicate checksum')
        checksums[name] = digest
    for path in (app_zip, source_zip):
        require(checksums.get(path.name) == sha(path.read_bytes()), 'published checksum mismatch: ' + path.name)
    if installed is not None:
        require(installed.is_dir() and not installed.is_symlink(), 'installed app missing or unsafe')
        actual = {}
        for path in installed.rglob('*'):
            require(not path.is_symlink(), 'installed app contains a symlink')
            if path.is_file():
                actual[path.relative_to(installed).as_posix()] = path.read_bytes()
        require(actual == app, 'installed application differs from release archive')
    return {'schemaVersion': 1, 'bundleID': info['CFBundleIdentifier'], 'version': info['CFBundleShortVersionString'],
            'build': info['CFBundleVersion'], 'sourceCommit': commit, 'sourceFileCount': len(source), 'applicationFileCount': len(app),
            'installedVerified': installed is not None, 'applicationSHA256': sha(app_zip.read_bytes()),
            'sourceSHA256': sha(source_zip.read_bytes()), 'smokeTestPerformed': False}

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--app-zip', required=True, type=pathlib.Path)
    parser.add_argument('--source-zip', required=True, type=pathlib.Path)
    parser.add_argument('--checksums', required=True, type=pathlib.Path)
    parser.add_argument('--commit', default='HEAD')
    parser.add_argument('--installed', type=pathlib.Path)
    parser.add_argument('--report', type=pathlib.Path)
    args = parser.parse_args()
    report = verify(args.app_zip, args.source_zip, args.checksums, args.commit, args.installed)
    output = json.dumps(report, ensure_ascii=False, indent=2) + '\n'
    if args.report:
        require(not args.report.exists(), 'report already exists')
        args.report.write_text(output)
    print(output, end='')
