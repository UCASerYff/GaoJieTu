#!/usr/bin/env python3
"""Self-generated private fixtures only. Never reads the installed app or real app data."""
import base64
import contextlib
import errno
import hashlib
import importlib.util
import io
import json
import os
import pathlib
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
import uuid
from unittest import mock

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('gao_backup', pathlib.Path(__file__).with_name('backup.py'))
backup_module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(backup_module)

class BackupTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='GaoJieTu-BackupTests-', dir='/private/tmp')
        self.base = pathlib.Path(self.temporary.name)
        self.root = self.base / 'GaoJieTu'
        self.root.mkdir(mode=0o700)
        self.settings = {'schemaVersion': 1, 'historyEnabled': True, 'historyDays': 7, 'historyCapacityMB': 512,
                         'captureStrategy': '标注', 'languages': ['zh-Hans', 'en-US'], 'silentOCRCopies': True, 'pins': []}
        self.write_json('Settings.json', self.settings)
    def tearDown(self):
        for path in self.base.rglob('*'):
            if not path.is_symlink():
                try:
                    path.chmod(0o700 if path.is_dir() else 0o600)
                except OSError:
                    pass
        self.temporary.cleanup()
    def write_json(self, relative, value):
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        path.write_text(json.dumps(value, ensure_ascii=False), encoding='utf-8')
        path.chmod(0o600)
    def run_backup(self, **kwargs):
        with contextlib.redirect_stdout(io.StringIO()):
            return backup_module.backup(self.root, self.base / ('Backup-' + uuid.uuid4().hex), **kwargs)
    def history(self):
        png = base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aZMsAAAAASUVORK5CYII=')
        directory = self.root / 'History'
        directory.mkdir(mode=0o700)
        attachment = directory / 'sample.png'
        attachment.write_bytes(png)
        attachment.chmod(0o600)
        asset = {'id': str(uuid.uuid4()), 'createdAt': 812345678.0, 'source': '自建1px图片', 'pixelWidth': 1, 'pixelHeight': 1,
                 'colorSpace': 'sRGB', 'scale': 1.0, 'outputPath': 'History/sample.png', 'sha256': hashlib.sha256(png).hexdigest(), 'editVersion': 0}
        self.write_json('History.json', {'schemaVersion': 1, 'assets': [asset]})
        return attachment, asset
    def test_complete_backup_and_restore_rehearsal(self):
        attachment, asset = self.history()
        (self.root / 'Pins').mkdir(mode=0o700)
        pin = self.root / 'Pins/pin.png'
        pin.write_bytes(attachment.read_bytes())
        pin.chmod(0o600)
        self.write_json('PinnedImages.json', {'schemaVersion': 1, 'records': [
            {'imagePath': str(pin), 'windowFrame': '{{80, 100}, {100, 100}}', 'imageScale': 1.0, 'opacity': 1.0}]})
        self.write_json('Exchange/ProcessedRequests.json', {'schemaVersion': 1, 'records': []})
        (self.root / 'EmptyDirectory').mkdir(mode=0o700)
        report = self.run_backup()
        self.assertTrue(report['verified'] and report['restoreRehearsal'])
        self.assertEqual(report['integrity']['historyAssets'], 1)
        self.assertEqual(report['integrity']['persistentPins'], 1)
        self.assertIn('EmptyDirectory', report['directories'])
        self.assertEqual(report['inventory']['History/sample.png']['sha256'], asset['sha256'])
        self.assertEqual(attachment.read_bytes(), pin.read_bytes())
        self.assertEqual(report['keychain'], 'untouched')
        self.assertTrue(report['createdAt'].endswith('Z'))
    def test_missing_root_requires_explicit_first_install(self):
        absent = self.base / 'MissingData'
        with self.assertRaises(FileNotFoundError):
            backup_module.inventory(absent)
        with contextlib.redirect_stdout(io.StringIO()):
            report = backup_module.backup(absent, self.base / 'FirstInstall', allow_missing=True)
        self.assertFalse(report['sourceExisted'])
        self.assertTrue(report['sourceMissingExplicitlyAllowed'])
        self.assertFalse(absent.exists())
    def test_dangling_root_link_never_means_empty(self):
        link = self.base / 'Dangling'
        link.symlink_to(self.base / 'NotThere')
        with self.assertRaises(OSError):
            backup_module.backup(link, self.base / 'Rejected', allow_missing=True)
        self.assertTrue(link.is_symlink())
        self.assertFalse((self.base / 'Rejected').exists())
    def test_live_root_link_rejected(self):
        link = self.base / 'LiveLink'
        link.symlink_to(self.root, target_is_directory=True)
        with self.assertRaises(OSError):
            backup_module.backup(link, self.base / 'Rejected')
    def test_eacces_is_not_missing(self):
        real_open = backup_module.os.open
        def denied(path, flags, *args, **kwargs):
            if path == 'GaoJieTu':
                raise PermissionError(errno.EACCES, 'self-generated denied fixture')
            return real_open(path, flags, *args, **kwargs)
        with mock.patch.object(backup_module.os, 'open', side_effect=denied):
            with self.assertRaises(PermissionError):
                backup_module.backup(self.root, self.base / 'Rejected', allow_missing=True)
        self.assertFalse((self.base / 'Rejected').exists())
    def test_unreadable_file_rejected(self):
        (self.root / 'Settings.json').chmod(0)
        with self.assertRaises((backup_module.BackupError, PermissionError)):
            self.run_backup()
    def test_untraversable_subdirectory_rejected(self):
        secret = self.root / 'Unreadable'
        secret.mkdir(mode=0o700)
        (secret / 'content').write_bytes(b'generated')
        secret.chmod(0)
        with self.assertRaises((backup_module.BackupError, PermissionError)):
            self.run_backup()
    def test_attachment_link_and_hardlink_rejected(self):
        attachment, _ = self.history()
        attachment.unlink()
        attachment.symlink_to(self.base / 'MissingImage')
        with self.assertRaises(backup_module.BackupError):
            self.run_backup()
        attachment.unlink()
        source = self.base / 'SelfGenerated'
        source.write_bytes(b'generated')
        os.link(source, attachment)
        with self.assertRaises(backup_module.BackupError):
            self.run_backup()
    def test_missing_history_main_record(self):
        (self.root / 'History').mkdir(mode=0o700)
        with self.assertRaisesRegex(backup_module.BackupError, '主记录缺失'):
            self.run_backup()
    def test_missing_settings_with_business_data(self):
        self.history()
        (self.root / 'Settings.json').unlink()
        with self.assertRaisesRegex(backup_module.BackupError, 'Settings'):
            self.run_backup()
    def test_missing_history_attachment_and_sha_mismatch(self):
        attachment, _ = self.history()
        attachment.unlink()
        with self.assertRaisesRegex(backup_module.BackupError, '附件缺失'):
            self.run_backup()
        attachment.write_bytes(b'tampered self-generated fixture')
        with self.assertRaisesRegex(backup_module.BackupError, 'SHA256'):
            self.run_backup()
    def test_future_and_corrupt_schemas_preserved(self):
        for name, extra in [('Settings.json', self.settings), ('History.json', {'assets': []}),
                            ('PinnedImages.json', {'records': []}), ('Exchange/ProcessedRequests.json', {'records': []})]:
            with self.subTest(name=name):
                path = self.root / name
                previous = path.read_bytes() if path.exists() else None
                self.write_json(name, dict(extra, schemaVersion=2))
                unchanged = path.read_bytes()
                with self.assertRaises(backup_module.BackupError):
                    self.run_backup()
                self.assertEqual(path.read_bytes(), unchanged)
                if previous is not None:
                    path.write_bytes(previous)
                else:
                    path.unlink()
        (self.root / 'Settings.json').write_text('{broken', encoding='utf-8')
        with self.assertRaises(ValueError):
            self.run_backup()
    def test_duplicate_json_key_rejected(self):
        (self.root / 'Settings.json').write_text('{"schemaVersion":1,"schemaVersion":2}')
        with self.assertRaisesRegex(backup_module.BackupError, '重复键'):
            self.run_backup()
    def test_missing_pin_attachment_or_main(self):
        (self.root / 'Pins').mkdir(mode=0o700)
        with self.assertRaisesRegex(backup_module.BackupError, 'PinnedImages'):
            self.run_backup()
        self.write_json('PinnedImages.json', {'schemaVersion': 1, 'records': [
            {'imagePath': str(self.root / 'Pins/missing.png'), 'windowFrame': '{{0, 0}, {1, 1}}', 'imageScale': 1, 'opacity': 1}]})
        with self.assertRaisesRegex(backup_module.BackupError, '附件缺失'):
            self.run_backup()
    def test_missing_processed_requests_main_record(self):
        directory = self.root / 'Exchange/Derived' / str(uuid.uuid4())
        directory.mkdir(parents=True, mode=0o700)
        (directory / 'generated.txt').write_bytes(b'generated')
        with self.assertRaisesRegex(backup_module.BackupError, 'ProcessedRequests'):
            self.run_backup()
    def test_outgoing_manifest_attachment_and_digest(self):
        package = 'Exchange/Outgoing/' + str(uuid.uuid4()) + '.gaoaction'
        path = self.root / package / 'payload/input.txt'
        path.parent.mkdir(parents=True, mode=0o700)
        path.write_bytes(b'hello\n')
        manifest = {'schemaVersion': 1, 'kind': 'request', 'requestID': str(uuid.uuid4()), 'action': 'text.translate',
                    'sourceBundleID': 'com.gaoseries.GaoJieTu', 'targetBundleID': 'com.gaoseries.GaoWenJian',
                    'createdAt': '2026-10-12T12:00:00Z', 'expiresAt': '2026-10-12T12:02:00Z',
                    'nonce': base64.b64encode(bytes(32)).decode(), 'parameters': {'targetLanguage': 'en-US'}, 'references': [],
                    'items': [{'id': 'text', 'relativePath': 'payload/input.txt', 'uti': 'public.plain-text', 'byteCount': 6,
                               'sha256': hashlib.sha256(b'hello\n').hexdigest()}]}
        self.write_json(package + '/manifest.json', manifest)
        self.assertEqual(self.run_backup()['integrity']['outgoingPackages'], 1)
        path.write_bytes(b'changed')
        with self.assertRaisesRegex(backup_module.BackupError, 'SHA256'):
            self.run_backup()

    def writer_package(self, relative='A1B2C3D4-自建 文本.txt', *, staged=False, physical=None):
        request_id = str(uuid.uuid4())
        base = ('Exchange/Staging/' + request_id) if staged else ('Exchange/Outgoing/' + request_id + '.gaoaction')
        manifest = {'schemaVersion': 1, 'kind': 'request', 'requestID': request_id, 'action': 'text.translate',
                    'sourceBundleID': 'com.gaoseries.GaoJieTu', 'targetBundleID': 'com.gaoseries.GaoJieTu',
                    'createdAt': '2026-10-18T12:00:00Z', 'expiresAt': '2026-10-18T12:02:00Z',
                    'nonce': base64.b64encode(bytes(32)).decode(), 'parameters': {'targetLanguage': 'en-US'}, 'references': [],
                    'items': [{'id': 'text', 'relativePath': relative, 'uti': 'text/plain', 'byteCount': 6,
                               'sha256': hashlib.sha256(b'hello\n').hexdigest()}]}
        if physical is None:
            physical = ('0-' + backup_module.safe_filename(pathlib.PurePosixPath(relative).name)) if staged else ('payload/' + relative)
        path = self.root / base / physical
        path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        path.write_bytes(b'hello\n')
        path.chmod(0o600)
        self.write_json(base + '/manifest.json', manifest)
        if staged:
            self.write_json('Exchange/ProcessedRequests.json', {'schemaVersion': 1, 'records': []})
        return base, manifest, path

    def test_writer_bare_relative_path_backup_and_restore(self):
        base, manifest, path = self.writer_package()
        report = self.run_backup()
        self.assertEqual(report['integrity']['outgoingPackages'], 1)
        self.assertTrue(report['restoreRehearsal'])
        self.assertEqual(report['inventory'][base + '/payload/' + manifest['items'][0]['relativePath']]['sha256'],
                         hashlib.sha256(b'hello\n').hexdigest())

    def test_writer_staging_uses_indexed_safe_last_component(self):
        base, manifest, path = self.writer_package('folder/A1B2C3D4-自建 文本.txt', staged=True)
        report = self.run_backup()
        self.assertEqual(report['integrity']['stagedPackages'], 1)
        self.assertIn(base + '/0-A1B2C3D4-自建 文本.txt', report['inventory'])

    def test_writer_nested_relative_path_is_payload_rooted(self):
        self.writer_package('folder/subfolder/A1B2C3D4-note.txt')
        self.assertEqual(self.run_backup()['integrity']['outgoingPackages'], 1)

    def test_legacy_prefix_requires_unambiguous_physical_match(self):
        self.writer_package('payload/input.txt', physical='payload/input.txt')
        self.assertEqual(self.run_backup()['integrity']['outgoingPackages'], 1)

    def test_literal_payload_subfolder_is_canonical_when_unambiguous(self):
        self.writer_package('payload/input.txt')
        self.assertEqual(self.run_backup()['integrity']['outgoingPackages'], 1)

    def test_ambiguous_new_and_legacy_payload_paths_are_rejected(self):
        base, manifest, path = self.writer_package('payload/input.txt')
        legacy = self.root / base / 'payload/input.txt'
        legacy.write_bytes(b'hello\n')
        with self.assertRaisesRegex(backup_module.BackupError, '歧义'):
            self.run_backup()

    def test_legacy_alias_cannot_repeat_a_bare_path_attachment(self):
        base, manifest, path = self.writer_package('input.txt')
        duplicate = dict(manifest['items'][0], id='duplicate', relativePath='payload/input.txt')
        manifest['items'].append(duplicate)
        self.write_json(base + '/manifest.json', manifest)
        with self.assertRaisesRegex(backup_module.BackupError, '同一文件'):
            self.run_backup()

    def test_bare_relative_path_digest_mismatch_and_missing_are_rejected(self):
        base, manifest, path = self.writer_package()
        path.write_bytes(b'other\n')
        with self.assertRaisesRegex(backup_module.BackupError, 'SHA256'):
            self.run_backup()
        path.unlink()
        with self.assertRaisesRegex(backup_module.BackupError, '附件缺失'):
            self.run_backup()

    def test_bare_relative_path_symlink_and_hardlink_are_rejected(self):
        base, manifest, path = self.writer_package()
        path.unlink()
        external = self.base / 'SelfGeneratedPayload.txt'
        external.write_bytes(b'hello\n')
        path.symlink_to(external)
        with self.assertRaises(backup_module.BackupError):
            self.run_backup()
        path.unlink()
        os.link(external, path)
        with self.assertRaises(backup_module.BackupError):
            self.run_backup()

    def test_bare_relative_path_traversal_and_absolute_still_rejected(self):
        base, manifest, path = self.writer_package()
        for relative in ('../input.txt', 'folder/../../input.txt', '/input.txt', 'folder//input.txt', 'folder/./input.txt'):
            with self.subTest(relative=relative):
                manifest['items'][0]['relativePath'] = relative
                self.write_json(base + '/manifest.json', manifest)
                with self.assertRaises(backup_module.BackupError):
                    self.run_backup()
    def test_traversal_record_and_destination_rejected(self):
        attachment, asset = self.history()
        asset['outputPath'] = 'History/../Settings.json'
        self.write_json('History.json', {'schemaVersion': 1, 'assets': [asset]})
        with self.assertRaises(backup_module.BackupError):
            self.run_backup()
        with self.assertRaises(backup_module.BackupError):
            backup_module.backup(self.root, self.root / 'Backup')
    def test_destination_link_rejected(self):
        destination = self.base / 'ExistingLink'
        destination.symlink_to(self.base / 'NonexistentTarget')
        with self.assertRaises(FileExistsError):
            backup_module.backup(self.root, destination)
        self.assertTrue(destination.is_symlink())

    def prepare_rollback(self, *, previous=True, current_bundle='com.gaoseries.GaoJieTu'):
        project = self.base / 'Project'
        (project / 'Scripts').mkdir(parents=True)
        (project / 'TestResults').mkdir()
        shutil.copyfile(pathlib.Path(__file__).with_name('backup.py'), project / 'Scripts/backup.py')
        target = self.base / 'Applications/搞截图.app'
        def app(path, version, bundle='com.gaoseries.GaoJieTu'):
            (path / 'Contents/MacOS').mkdir(parents=True)
            (path / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': bundle,
                'CFBundleShortVersionString': version, 'CFBundleVersion': '1', 'CFBundleExecutable': 'GaoJieTu'}))
            (path / 'Contents/MacOS/GaoJieTu').write_bytes(b'self-generated mock app, never executed')
        app(target, '1.01', current_bundle)
        backup = self.base / 'GaoJieTu-Backups/Backup-rollback-test'
        with contextlib.redirect_stdout(io.StringIO()):
            backup_module.backup(self.root, backup)
        if previous:
            app(backup / 'PreviousInstalled.app', '1.00')
        (backup / 'Installation.json').write_text(json.dumps({'schemaVersion': 1, 'bundleID': 'com.gaoseries.GaoJieTu',
            'targetPath': str(target), 'hadPreviousApp': previous}))
        (project / 'TestResults/LatestInstallationBackup.txt').write_text(str(backup) + '\n')
        program = pathlib.Path(__file__).with_name('rollback.sh').read_text().partition("<<'PY'\n")[2].rsplit('\nPY\n', 1)[0]
        # Modify only this in-memory test copy. The production script accepts no alternate installation target.
        program = program.replace('project = pathlib.Path.cwd()', 'project = pathlib.Path(' + repr(str(project)) + ')')
        program = program.replace("TARGET = pathlib.Path('/Applications/搞截图.app')", 'TARGET = pathlib.Path(' + repr(str(target)) + ')')
        program = program.replace("DATA = pathlib.Path.home() / 'Library/Application Support/GaoSeries/GaoJieTu'", 'DATA = pathlib.Path(' + repr(str(self.root)) + ')')
        return program, target, backup

    def execute_isolated_rollback(self, program, *, bad_current_signature=False, target=None):
        calls = []
        def run(args, **kwargs):
            calls.append(args)
            if args[0] == '/usr/bin/ditto':
                shutil.copytree(args[1], args[2])
            code = 1 if bad_current_signature and args[0] == '/usr/bin/codesign' and args[-1] == str(target) else 0
            return subprocess.CompletedProcess(args, code, stdout=b'', stderr=b'')
        output, errors = io.StringIO(), io.StringIO()
        with mock.patch.object(sys, 'argv', ['isolated-rollback', '']), mock.patch('subprocess.run', side_effect=run), \
             contextlib.redirect_stdout(output), contextlib.redirect_stderr(errors):
            exec(compile(program, '<isolated rollback script>', 'exec'), {'__name__': '__main__'})
        return calls

    def test_rollback_preserves_failed_app_and_restores_old_bundle_without_data_changes(self):
        program, target, backup = self.prepare_rollback()
        before = backup_module.inventory(self.root)
        self.execute_isolated_rollback(program)
        info = plistlib.loads((target / 'Contents/Info.plist').read_bytes())
        self.assertEqual(info['CFBundleShortVersionString'], '1.00')
        failed = list(backup.glob('FailedNewRollback-*.app'))
        self.assertEqual(len(failed), 1)
        self.assertEqual(plistlib.loads((failed[0] / 'Contents/Info.plist').read_bytes())['CFBundleShortVersionString'], '1.01')
        self.assertTrue((backup / 'PreviousInstalled.app').exists())
        self.assertEqual(before, backup_module.inventory(self.root))

    def test_first_install_rollback_withdraws_only_own_app_and_keeps_data(self):
        program, target, backup = self.prepare_rollback(previous=False)
        sibling = target.parent / '其他搞系列.app'
        sibling.mkdir()
        marker = sibling / 'do-not-touch'
        marker.write_bytes(b'sibling self-generated fixture')
        before = backup_module.inventory(self.root)
        self.execute_isolated_rollback(program)
        self.assertFalse(target.exists())
        self.assertEqual(len(list(backup.glob('FailedNewRollback-*.app'))), 1)
        self.assertEqual(marker.read_bytes(), b'sibling self-generated fixture')
        self.assertEqual(before, backup_module.inventory(self.root))

    def test_rollback_accepts_matching_bundle_with_failed_new_signature(self):
        program, target, backup = self.prepare_rollback(previous=False)
        self.execute_isolated_rollback(program, bad_current_signature=True, target=target)
        self.assertFalse(target.exists())
        self.assertEqual(len(list(backup.glob('FailedNewRollback-*.app'))), 1)

    def test_rollback_rejects_other_bundle_without_mutation(self):
        program, target, backup = self.prepare_rollback(current_bundle='org.other.App')
        with self.assertRaises(SystemExit) as failure:
            self.execute_isolated_rollback(program)
        self.assertEqual(failure.exception.code, 1)
        self.assertTrue(target.exists())
        self.assertFalse(list(backup.glob('FailedNewRollback-*.app')))

    def test_rollback_does_not_guess_first_install_when_previous_app_missing(self):
        program, target, backup = self.prepare_rollback()
        shutil.rmtree(backup / 'PreviousInstalled.app')
        with self.assertRaises(SystemExit) as failure:
            self.execute_isolated_rollback(program)
        self.assertEqual(failure.exception.code, 1)
        self.assertTrue(target.exists())
        self.assertFalse(list(backup.glob('FailedNewRollback-*.app')))

    def prepare_install(self, *, previous=True):
        project = self.base / 'InstallProject'
        (project / 'Scripts').mkdir(parents=True)
        (project / 'TestResults').mkdir()
        shutil.copyfile(pathlib.Path(__file__).with_name('backup.py'), project / 'Scripts/backup.py')
        target = self.base / 'Applications/搞截图.app'
        target.parent.mkdir(exist_ok=True)
        def app(path, version, build):
            (path / 'Contents/MacOS').mkdir(parents=True)
            (path / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': 'com.gaoseries.GaoJieTu',
                'CFBundleShortVersionString': version, 'CFBundleVersion': build, 'CFBundleExecutable': 'GaoJieTu'}))
            (path / 'Contents/MacOS/GaoJieTu').write_bytes(('generated mock app ' + version).encode())
        app(project / '.build.noindex/搞截图.app', '1.01', '2')
        if previous:
            app(target, '1.00', '1')
        program = pathlib.Path(__file__).with_name('install.sh').read_text().partition("<<'PY'\n")[2].rsplit('\nPY\n', 1)[0]
        program = program.replace('project = pathlib.Path.cwd()', 'project = pathlib.Path(' + repr(str(project)) + ')')
        program = program.replace("TARGET = pathlib.Path('/Applications/搞截图.app')", 'TARGET = pathlib.Path(' + repr(str(target)) + ')')
        program = program.replace("DATA = pathlib.Path.home() / 'Library/Application Support/GaoSeries/GaoJieTu'", 'DATA = pathlib.Path(' + repr(str(self.root)) + ')')
        return program, target, project

    def execute_isolated_install(self, program, *, stage_wrong_bundle=False, fail_installed_signature=False,
                                 fail_registration=False, target=None):
        calls = []
        def run(args, **kwargs):
            calls.append(args)
            code = 0
            if args[0] == '/usr/bin/pgrep':
                code = 1
            elif args[0] == '/usr/bin/ditto':
                shutil.copytree(args[1], args[2], dirs_exist_ok=True)
                if stage_wrong_bundle and pathlib.Path(args[2]).parent.name.startswith('.GaoJieTu-stage-'):
                    path = pathlib.Path(args[2]) / 'Contents/Info.plist'
                    info = plistlib.loads(path.read_bytes())
                    info['CFBundleIdentifier'] = 'org.other.App'
                    path.write_bytes(plistlib.dumps(info))
            elif args[0] == '/usr/bin/codesign' and fail_installed_signature and args[-1] == str(target):
                path = target / 'Contents/Info.plist'
                code = 1 if plistlib.loads(path.read_bytes())['CFBundleShortVersionString'] == '1.01' else 0
            elif args[0].endswith('/lsregister') and fail_registration and args[-2:] == ['-f', str(target)]:
                code = 1 if plistlib.loads((target / 'Contents/Info.plist').read_bytes())['CFBundleShortVersionString'] == '1.01' else 0
            return subprocess.CompletedProcess(args, code, stdout=b'', stderr=b'')
        with mock.patch('subprocess.run', side_effect=run), contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            exec(compile(program, '<isolated install script>', 'exec'), {'__name__': '__main__'})
        return calls

    def test_install_success_preserves_old_app_data_and_atomic_pointer(self):
        program, target, project = self.prepare_install()
        before = backup_module.inventory(self.root)
        self.execute_isolated_install(program, target=target)
        self.assertEqual(plistlib.loads((target / 'Contents/Info.plist').read_bytes())['CFBundleShortVersionString'], '1.01')
        backup = pathlib.Path((project / 'TestResults/LatestInstallationBackup.txt').read_text().strip())
        self.assertTrue(backup.name.endswith('.noindex'))
        receipt = json.loads((backup / 'Installation.json').read_text())
        self.assertIs(receipt['hadPreviousApp'], True)
        self.assertTrue((backup / 'Previous.app').exists() and (backup / 'PreviousInstalled.app').exists())
        self.assertTrue((backup / 'InstallationCompleted.json').exists())
        self.assertEqual(before, backup_module.inventory(self.root))
        self.assertFalse((target.parent / '.GaoJieTu-install.lock').exists())
        self.assertFalse(list((project / 'TestResults').glob('*.tmp')))
        self.assertFalse(list(target.parent.glob('.GaoJieTu-stage-*')))

    def test_first_install_preserves_other_apps(self):
        program, target, project = self.prepare_install(previous=False)
        sibling = target.parent / '搞文件.app'
        sibling.mkdir()
        (sibling / 'fixture').write_bytes(b'preserve another app')
        self.execute_isolated_install(program, target=target)
        backup = pathlib.Path((project / 'TestResults/LatestInstallationBackup.txt').read_text().strip())
        self.assertIs(json.loads((backup / 'Installation.json').read_text())['hadPreviousApp'], False)
        self.assertFalse((backup / 'Previous.app').exists())
        self.assertEqual((sibling / 'fixture').read_bytes(), b'preserve another app')

    def test_stage_bundle_change_rejected_before_replacing_old_app(self):
        program, target, project = self.prepare_install()
        before = backup_module.inventory(self.root)
        with self.assertRaises(SystemExit):
            self.execute_isolated_install(program, stage_wrong_bundle=True, target=target)
        self.assertEqual(plistlib.loads((target / 'Contents/Info.plist').read_bytes())['CFBundleShortVersionString'], '1.00')
        self.assertEqual(before, backup_module.inventory(self.root))
        self.assertFalse((project / 'TestResults/LatestInstallationBackup.txt').exists())
        self.assertFalse(list(target.parent.glob('.GaoJieTu-stage-*')))

    def test_signature_failure_after_install_archives_new_and_restores_old(self):
        program, target, project = self.prepare_install()
        before = backup_module.inventory(self.root)
        with self.assertRaises(SystemExit):
            self.execute_isolated_install(program, fail_installed_signature=True, target=target)
        self.assertEqual(plistlib.loads((target / 'Contents/Info.plist').read_bytes())['CFBundleShortVersionString'], '1.00')
        backups = list((self.base / 'GaoJieTu-Backups').glob('Backup-*'))
        self.assertEqual(len(list(backups[0].glob('FailedNew-*.app'))), 1)
        self.assertTrue((backups[0] / 'Previous.app').exists())
        self.assertEqual(before, backup_module.inventory(self.root))

    def test_first_install_registration_failure_withdraws_new_app_only(self):
        program, target, project = self.prepare_install(previous=False)
        before = backup_module.inventory(self.root)
        with self.assertRaises(SystemExit):
            self.execute_isolated_install(program, fail_registration=True, target=target)
        self.assertFalse(target.exists())
        backups = list((self.base / 'GaoJieTu-Backups').glob('Backup-*'))
        self.assertEqual(len(list(backups[0].glob('FailedNew-*.app'))), 1)
        self.assertEqual(before, backup_module.inventory(self.root))

    def test_pointer_link_is_not_overwritten_and_install_rolls_back(self):
        program, target, project = self.prepare_install()
        original = self.base / 'unrelated-file'
        original.write_bytes(b'not a pointer')
        pointer = project / 'TestResults/LatestInstallationBackup.txt'
        pointer.symlink_to(original)
        with self.assertRaises(SystemExit):
            self.execute_isolated_install(program, target=target)
        self.assertTrue(pointer.is_symlink())
        self.assertEqual(original.read_bytes(), b'not a pointer')
        self.assertEqual(plistlib.loads((target / 'Contents/Info.plist').read_bytes())['CFBundleShortVersionString'], '1.00')

    def test_install_target_eacces_does_not_become_first_install(self):
        program, target, project = self.prepare_install()
        original_lstat = pathlib.Path.lstat
        def denied(path, *args, **kwargs):
            if os.fspath(path) == str(target):
                raise PermissionError(errno.EACCES, 'generated target EACCES fixture')
            return original_lstat(path, *args, **kwargs)
        with mock.patch.object(pathlib.Path, 'lstat', new=denied):
            with self.assertRaises(SystemExit):
                self.execute_isolated_install(program, target=target)
        self.assertEqual(plistlib.loads((target / 'Contents/Info.plist').read_bytes())['CFBundleShortVersionString'], '1.00')
        self.assertFalse((self.base / 'GaoJieTu-Backups').exists())

    def test_install_and_rollback_both_reject_the_same_held_lock(self):
        program, target, project = self.prepare_install()
        lock = target.parent / '.GaoJieTu-install.lock'
        lock.mkdir(mode=0o700)
        (lock / 'Owner.json').write_bytes(b'lock held by a different self-generated fixture')
        with self.assertRaises(SystemExit):
            self.execute_isolated_install(program, target=target)
        self.assertEqual((lock / 'Owner.json').read_bytes(), b'lock held by a different self-generated fixture')
        lock_name = '.GaoJieTu-install.lock'
        self.assertIn(lock_name, pathlib.Path(__file__).with_name('rollback.sh').read_text())

    def test_installation_receipt_is_exclusive_and_existing_bytes_are_preserved(self):
        program, target, project = self.prepare_install()
        original_open = os.open
        collided = False
        def inject_receipt(path, flags, mode=0o777, *, dir_fd=None):
            nonlocal collided
            if path == 'Installation.json' and flags & os.O_EXCL and not collided:
                descriptor = original_open(path, flags, mode, dir_fd=dir_fd)
                os.write(descriptor, b'preserved self-generated existing receipt')
                os.close(descriptor)
                collided = True
            return original_open(path, flags, mode, dir_fd=dir_fd)
        with mock.patch('os.open', side_effect=inject_receipt):
            with self.assertRaises(SystemExit):
                self.execute_isolated_install(program, target=target)
        self.assertTrue(collided)
        backups = list((self.base / 'GaoJieTu-Backups').glob('Backup-*'))
        self.assertEqual((backups[0] / 'Installation.json').read_bytes(), b'preserved self-generated existing receipt')
        self.assertEqual(plistlib.loads((target / 'Contents/Info.plist').read_bytes())['CFBundleShortVersionString'], '1.00')

    def test_rollback_rejects_held_install_lock_without_removing_it(self):
        program, target, backup = self.prepare_rollback()
        lock = target.parent / '.GaoJieTu-install.lock'
        lock.mkdir(mode=0o700)
        marker = lock / 'Owner.json'
        marker.write_bytes(b'held install lock fixture')
        with self.assertRaises(SystemExit):
            self.execute_isolated_rollback(program)
        self.assertTrue(target.exists())
        self.assertEqual(marker.read_bytes(), b'held install lock fixture')

if __name__ == '__main__':
    unittest.main(verbosity=2)
