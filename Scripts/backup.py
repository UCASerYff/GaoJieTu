#!/usr/bin/env python3
"""Private, fail-closed backup: fixed-FD reads, schema/attachment preflight and actual restore rehearsal."""
import argparse
import datetime
import hashlib
import json
import math
import os
import pathlib
import re
import stat
import sys
import unicodedata
import uuid

BUNDLE_ID = 'com.gaoseries.GaoJieTu'
MAIN_FILES = {'Settings.json', 'History.json', 'PinnedImages.json', 'Exchange/ProcessedRequests.json'}
KNOWN_ACTIONS = set('capture.region capture.window capture.display ocr.files images.annotate images.pin text.translate storage.inspect cleanup.review apps.uninstall.review files.search files.choose files.reveal associations.manage documents.open documents.newText research.importDocuments portal.openSite portal.openWorkspace portal.focusSearch portal.proposeSite portal.prepareDownload windows.overview desktop.openSettings downloads.prepare'.split())
PHASES = set('received approved executing completed partial cancelled failed unsupported'.split())
O_FLAGS = os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK

class BackupError(RuntimeError):
    pass

def require(condition, message):
    if not condition:
        raise BackupError(message)

def absolute(path):
    path = pathlib.Path(os.path.abspath(os.fspath(path)))
    require('..' not in path.parts, '路径包含越界分量')
    return path

def directory_fd(path, *, create=False, allow_missing=False):
    """No exists()/is_dir() ambiguity: only ENOENT may mean absent; EACCES and links always fail."""
    path = absolute(path)
    current = os.open('/', O_FLAGS | os.O_DIRECTORY)
    try:
        for component in path.parts[1:]:
            if create:
                try:
                    os.mkdir(component, 0o700, dir_fd=current)
                except FileExistsError:
                    pass
            try:
                child = os.open(component, O_FLAGS | os.O_DIRECTORY, dir_fd=current)
            except FileNotFoundError:
                if allow_missing:
                    os.close(current)
                    return None
                raise
            os.close(current)
            current = child
        return current
    except BaseException:
        os.close(current)
        raise

def signature(value):
    return (value.st_dev, value.st_ino, value.st_size, value.st_mtime_ns, value.st_ctime_ns, value.st_nlink)

def check_entry(value, kind):
    require(value.st_uid == os.getuid(), '资料对象不属于当前用户，停止备份')
    require(not stat.S_ISLNK(value.st_mode), '资料含符号链接（包括悬空链接），停止备份')
    require(kind(value.st_mode), '资料含不支持的对象类型，停止备份')
    if stat.S_ISREG(value.st_mode):
        require(value.st_nlink == 1, '资料含硬链接，停止备份')
        require(value.st_mode & 0o444 != 0, '资料文件没有读取权限，停止备份')
    else:
        require(value.st_mode & 0o500 == 0o500, '资料目录不可完整遍历，停止备份')

def snapshot(root, *, allow_missing=False, copy_to=None):
    """Return every file hash plus empty directories. Optional copy consumes the same opened source FDs."""
    root = absolute(root)
    root_fd = directory_fd(root, allow_missing=allow_missing)
    if root_fd is None:
        return {}, [], False
    target_fd = directory_fd(copy_to) if copy_to is not None else None
    files, directories = {}, []
    def visit(source_fd, prefix, destination_fd):
        before_directory = os.fstat(source_fd)
        check_entry(before_directory, stat.S_ISDIR)
        with os.scandir(source_fd) as entries:
            names = sorted(entry.name for entry in entries)
        for name in names:
            relative = prefix + name
            original = os.stat(name, dir_fd=source_fd, follow_symlinks=False)
            if stat.S_ISDIR(original.st_mode):
                check_entry(original, stat.S_ISDIR)
                child = os.open(name, O_FLAGS | os.O_DIRECTORY, dir_fd=source_fd)
                target = None
                try:
                    require(signature(os.fstat(child)) == signature(original), '资料目录身份在读取时改变')
                    directories.append(relative)
                    if destination_fd is not None:
                        os.mkdir(name, 0o700, dir_fd=destination_fd)
                        target = os.open(name, O_FLAGS | os.O_DIRECTORY, dir_fd=destination_fd)
                    visit(child, relative + '/', target)
                finally:
                    if target is not None:
                        os.close(target)
                    os.close(child)
            else:
                check_entry(original, stat.S_ISREG)
                source = os.open(name, O_FLAGS, dir_fd=source_fd)
                target = None
                try:
                    require(signature(os.fstat(source)) == signature(original), '资料文件身份在读取时改变')
                    if destination_fd is not None:
                        target = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600, dir_fd=destination_fd)
                    digest, count = hashlib.sha256(), 0
                    while True:
                        chunk = os.read(source, 1024 * 1024)
                        if not chunk:
                            break
                        digest.update(chunk)
                        count += len(chunk)
                        if target is not None:
                            view = memoryview(chunk)
                            while view:
                                written = os.write(target, view)
                                require(written > 0, '备份文件写入中断')
                                view = view[written:]
                    require(signature(os.fstat(source)) == signature(original) and count == original.st_size,
                            '资料在备份过程中改变，停止操作')
                    require(signature(os.stat(name, dir_fd=source_fd, follow_symlinks=False)) == signature(original),
                            '资料路径在读取过程中改变')
                    if target is not None:
                        os.utime(target, ns=(original.st_atime_ns, original.st_mtime_ns))
                        os.fsync(target)
                    files[relative] = {'bytes': count, 'sha256': digest.hexdigest()}
                finally:
                    if target is not None:
                        os.close(target)
                    os.close(source)
        require(signature(os.fstat(source_fd)) == signature(before_directory), '资料目录在遍历过程中改变')
        if destination_fd is not None:
            os.fsync(destination_fd)
    try:
        visit(root_fd, '', target_fd)
    finally:
        os.close(root_fd)
        if target_fd is not None:
            os.close(target_fd)
    return files, directories, True

def inventory(root, *, allow_missing=False):
    return snapshot(root, allow_missing=allow_missing)[0]

def regular_bytes(root, relative, maximum):
    parts = safe_relative(relative)
    parent = directory_fd(absolute(root).joinpath(*parts[:-1]))
    fd = None
    try:
        fd = os.open(parts[-1], O_FLAGS, dir_fd=parent)
        before = os.fstat(fd)
        check_entry(before, stat.S_ISREG)
        require(before.st_size <= maximum, '主记录超过安全大小预算')
        result = bytearray()
        while True:
            chunk = os.read(fd, min(65536, maximum + 1 - len(result)))
            if not chunk:
                break
            result.extend(chunk)
            require(len(result) <= maximum, '主记录在读取时增大，停止操作')
        require(signature(before) == signature(os.fstat(fd)), '主记录在读取时改变')
        return bytes(result)
    finally:
        if fd is not None:
            os.close(fd)
        os.close(parent)

def safe_relative(value):
    require(isinstance(value, str) and value and '\\' not in value and '\0' not in value,
            '记录包含无效附件路径')
    path = pathlib.PurePosixPath(value)
    require(not path.is_absolute() and all(p not in ('', '.', '..') for p in value.split('/')),
            '记录包含越界附件路径')
    require(str(path) == value, '附件路径不规范')
    return path.parts

def unique_pairs(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, 'JSON 主记录含重复键，停止操作')
        result[key] = value
    return result

def load_json(root, relative, files, maximum=16_777_216):
    data = regular_bytes(root, relative, maximum)
    require(relative in files and hashlib.sha256(data).hexdigest() == files[relative]['sha256'], '主记录在完整性预检时改变')
    value = json.loads(data, object_pairs_hook=unique_pairs,
                       parse_constant=lambda _: (_ for _ in ()).throw(BackupError('JSON 含非有限数值')))
    require(isinstance(value, dict), '主记录不是 JSON 对象')
    require(type(value.get('schemaVersion')) is int and value['schemaVersion'] == 1,
            '主记录损坏或版本过新；不会当作空白覆盖')
    return value

def integer(value, low, high):
    return type(value) is int and low <= value <= high

def number(value, low, high):
    return type(value) in (int, float) and math.isfinite(value) and low <= value <= high

def valid_uuid(value):
    if not isinstance(value, str):
        return False
    try:
        return str(uuid.UUID(value)) == value.lower()
    except ValueError:
        return False

def valid_sha(value):
    return isinstance(value, str) and re.fullmatch('[0-9a-f]{64}', value) is not None

def utc_date(value):
    if not isinstance(value, str) or not value.endswith('Z'):
        return False
    try:
        datetime.datetime.fromisoformat(value[:-1] + '+00:00')
        return True
    except ValueError:
        return False

def check_attachment(files, path, sha=None, size=None):
    safe_relative(path)
    require(path in files, '主记录引用的附件缺失或不可读取')
    if sha is not None:
        require(valid_sha(sha) and files[path]['sha256'] == sha, '附件 SHA256 与主记录不符，停止备份')
    if size is not None:
        require(integer(size, 0, 2_147_483_648) and files[path]['bytes'] == size, '附件字节数与主记录不符')

def safe_filename(value):
    value = ''.join(c for c in value if not unicodedata.category(c).startswith('C') and c not in '/\\')
    while len(value.encode('utf-8')) > 220:
        value = value[:-1]
    return value if value not in ('', '.', '..') else '交接文档'

def validate_package(root, base, files, *, staged=False):
    manifest_path = base + '/manifest.json'
    manifest = load_json(root, manifest_path, files, 1_048_576)
    require(manifest.get('kind') in ('request', 'result') and valid_uuid(manifest.get('requestID')) and
            manifest.get('action') in KNOWN_ACTIONS, '交接包主记录身份或动作无效')
    items = manifest.get('items')
    require(isinstance(items, list) and len(items) <= 256, '交接附件列表无效')
    paths, targets, total = set(), set(), 0
    for index, item in enumerate(items):
        require(isinstance(item, dict), '交接附件记录损坏')
        relative = item.get('relativePath')
        parts = safe_relative(relative)
        require(relative not in paths, '交接附件路径重复')
        paths.add(relative)
        if staged:
            # GaoActionTransport flattens private copies to <index>-<safe last component>.
            target = base + '/' + str(index) + '-' + safe_filename(parts[-1])
        else:
            # V1 paths are relative to the payload directory, not the package root.
            target = base + '/payload/' + relative
            if len(parts) >= 2 and parts[0] == 'payload':
                # Older local packages included the payload/ prefix. Accept only one existing
                # physical file; never guess between a canonical nested payload folder and legacy.
                legacy = base + '/' + relative
                candidates = [candidate for candidate in (target, legacy) if candidate in files]
                require(len(candidates) <= 1, '交接附件新旧路径解释有歧义，停止备份')
                if candidates:
                    target = candidates[0]
        require(target not in targets, '交接附件多条路径指向同一文件，停止备份')
        targets.add(target)
        check_attachment(files, target, item.get('sha256'), item.get('byteCount'))
        require(valid_sha(item.get('sha256')) and integer(item.get('byteCount'), 0, 2_147_483_648), '交接附件缺少摘要或大小')
        total += item['byteCount']
    require(total <= 2_147_483_648, '交接载荷超过安全预算')
    if manifest['kind'] == 'result':
        require(valid_uuid(manifest.get('inReplyTo')) and manifest.get('status') in {'pending', 'completed', 'partial', 'cancelled', 'failed', 'unsupported'}, '交接结果关联或状态无效')
    return manifest

def preflight(root, files, directories, *, logical_root=None, source_existed=True):
    """Recognize the app's four persisted schemas and prove all their internal file references."""
    logical_root = absolute(logical_root or root)
    directory_set = set(directories)
    summary = {'settings': 'absent', 'historyAssets': 0, 'persistentPins': 0, 'processedRequests': 0,
               'outgoingPackages': 0, 'stagedPackages': 0,
               'externalReferences': 'manifest only; not copied or treated as transferred access',
               'pinnedSHA': 'PinnedImageRecord v1 has no stored SHA; complete snapshot SHA is verified'}
    if 'Settings.json' in files:
        settings = load_json(root, 'Settings.json', files, 1_048_576)
        require(type(settings.get('historyEnabled')) is bool and type(settings.get('silentOCRCopies')) is bool and
                integer(settings.get('historyDays'), 1, 3650) and integer(settings.get('historyCapacityMB'), 16, 16384) and
                settings.get('captureStrategy') in ('标注', '复制', '保存'), 'Settings 主记录缺字段或参数损坏')
        require(isinstance(settings.get('languages'), list) and 1 <= len(settings['languages']) <= 32 and
                all(isinstance(v, str) and 0 < len(v) <= 128 for v in settings['languages']) and
                isinstance(settings.get('pins'), list) and all(isinstance(v, str) for v in settings['pins']), 'Settings 语言或贴图列表损坏')
        for field in ('saveDirectory', 'editorPath'):
            require(settings.get(field) is None or isinstance(settings[field], str), 'Settings 路径字段损坏')
        require(not settings['pins'], '检测到旧格式 Settings.pins 数据，需核验迁移后再备份；不会忽略附件')
        summary['settings'] = 'validated schema 1'
    else:
        # Empty first-launch roots/Exchange may exist before the user first saves settings.
        business_files = [p for p in files if not p.startswith('Exchange/Outgoing/')]
        require(not business_files, '已有业务资料但 Settings 主记录缺失，停止安装以供核验')
        summary['settings'] = 'first-launch unsaved defaults; no dependent business records'
    require('History' not in directory_set or 'History.json' in files, 'History 附件目录存在但主记录缺失')
    if 'History.json' in files:
        assets = load_json(root, 'History.json', files).get('assets')
        require(isinstance(assets, list) and len(assets) <= 100_000, 'History 主记录缺失 assets 或数量超限')
        ids, paths = set(), set()
        for asset in assets:
            require(isinstance(asset, dict) and valid_uuid(asset.get('id')) and asset['id'] not in ids,
                    'History 记录身份损坏或重复')
            ids.add(asset['id'])
            path = asset.get('outputPath')
            parts = safe_relative(path)
            require(parts[0] == 'History' and len(parts) >= 2 and path not in paths, 'History 附件路径越界或重复')
            paths.add(path)
            require(integer(asset.get('pixelWidth'), 1, 30000) and integer(asset.get('pixelHeight'), 1, 30000) and
                    asset['pixelWidth'] * asset['pixelHeight'] <= 100_000_000 and number(asset.get('scale'), 0.001, 8) and
                    integer(asset.get('editVersion'), 0, 2_147_483_647) and isinstance(asset.get('source'), str) and
                    isinstance(asset.get('colorSpace'), str) and number(asset.get('createdAt'), -1e12, 1e12), 'History 图像元数据损坏')
            check_attachment(files, path, asset.get('sha256'))
            require(valid_sha(asset.get('sha256')), 'History 附件缺少原摘要')
        summary['historyAssets'] = len(assets)
    require('Pins' not in directory_set or 'PinnedImages.json' in files, 'Pins 附件目录存在但 PinnedImages 主记录缺失')
    if 'PinnedImages.json' in files:
        pins = load_json(root, 'PinnedImages.json', files, 1_048_576).get('records')
        require(isinstance(pins, list) and len(pins) <= 50, 'PinnedImages 主记录损坏或超限')
        paths = set()
        for pin in pins:
            require(isinstance(pin, dict) and isinstance(pin.get('imagePath'), str), '贴图路径缺失')
            path = pathlib.Path(pin['imagePath'])
            require(path.is_absolute() and '..' not in path.parts and path.parent == logical_root / 'Pins', '贴图原路径不在本 App 明确保存目录内')
            relative = 'Pins/' + path.name
            require(relative not in paths and isinstance(pin.get('windowFrame'), str) and
                    number(pin.get('imageScale'), 0.001, 8) and number(pin.get('opacity'), 0.15, 1), '贴图参数损坏或重复')
            paths.add(relative)
            check_attachment(files, relative, pin.get('sha256'))
        summary['persistentPins'] = len(pins)
    ledger_path = 'Exchange/ProcessedRequests.json'
    active_exchange = any(p.startswith(('Exchange/Staging/', 'Exchange/Derived/')) for p in files)
    require(not active_exchange or ledger_path in files, '交接资料存在但 ProcessedRequests 主记录缺失')
    if ledger_path in files:
        records = load_json(root, ledger_path, files).get('records')
        require(isinstance(records, list) and len(records) <= 100_000, 'ProcessedRequests 主记录损坏或超限')
        ids = set()
        for record in records:
            require(isinstance(record, dict) and valid_uuid(record.get('requestID')) and record['requestID'] not in ids and
                    valid_sha(record.get('manifestSHA256')) and record.get('action') in KNOWN_ACTIONS and
                    record.get('kind') in ('request', 'result') and record.get('phase') in PHASES and
                    utc_date(record.get('receivedAt')) and utc_date(record.get('updatedAt')) and
                    isinstance(record.get('sourceBundleID'), str) and re.fullmatch('[A-Za-z0-9.-]{1,255}', record['sourceBundleID']) is not None and
                    '.' in record['sourceBundleID'], 'ProcessedRequests 记录身份、状态或摘要损坏')
            ids.add(record['requestID'])
            if record.get('resultPackageName') is not None:
                name = record['resultPackageName']
                require(isinstance(name, str) and len(name.encode('utf-8')) <= 128 and name.endswith('.gaoaction') and '/' not in name and '\\' not in name and '\0' not in name,
                        '交接结果路径越界')
                require('Exchange/Outgoing/' + name + '/manifest.json' in files, '交接结果包缺失或主记录缺失')
        summary['processedRequests'] = len(records)
    for base in directories:
        parts = base.split('/')
        if len(parts) == 3 and parts[:2] == ['Exchange', 'Outgoing']:
            require(parts[-1].endswith('.gaoaction'), 'Outgoing 包名称无效或未完成')
            validate_package(root, base, files)
            summary['outgoingPackages'] += 1
        elif len(parts) == 3 and parts[:2] == ['Exchange', 'Staging']:
            require(valid_uuid(parts[-1]), 'Staging 目录身份损坏')
            validate_package(root, base, files, staged=True)
            summary['stagedPackages'] += 1
    return summary

def backup(root, destination, *, allow_missing=False):
    root, destination = absolute(root), absolute(destination)
    require(destination != root and root not in destination.parents and destination not in root.parents,
            '备份目标必须为资料目录以外的新目录')
    files, directories, existed = snapshot(root, allow_missing=allow_missing)
    summary = preflight(root, files, directories, logical_root=root, source_existed=existed)
    parent = directory_fd(destination.parent, create=True)
    try:
        os.mkdir(destination.name, 0o700, dir_fd=parent)
    finally:
        os.close(parent)
    data = destination / 'Data'
    data.mkdir(mode=0o700)
    if existed:
        copied = snapshot(root, copy_to=data)
        require(copied == (files, directories, True), '资料在复制时变化，未确认备份成功')
    require(snapshot(data) == (files, directories, True), '备份副本摘要或目录核验失败')
    require(snapshot(root, allow_missing=not existed) == (files, directories, existed), '原资料在备份过程中变化')
    require(preflight(data, files, directories, logical_root=root) == summary, '备份副本业务完整性核验失败')
    rehearsal = destination / 'RestoreRehearsal'
    rehearsal.mkdir(mode=0o700)
    require(snapshot(data, copy_to=rehearsal) == (files, directories, True), '恢复演练复制失败')
    require(snapshot(rehearsal) == (files, directories, True) and
            preflight(rehearsal, files, directories, logical_root=root) == summary, '恢复演练业务完整性或摘要核验失败')
    # Remove only this successful, freshly created rehearsal; failed data is never discarded.
    import shutil
    shutil.rmtree(rehearsal)
    report = {'schemaVersion': 1, 'sourceExisted': existed, 'sourceMissingExplicitlyAllowed': not existed and allow_missing,
              'fileCount': len(files), 'directories': directories, 'inventory': files, 'integrity': summary,
              'verified': True, 'restoreRehearsal': True, 'keychain': 'untouched',
              'createdAt': datetime.datetime.now(datetime.timezone.utc).isoformat(timespec='seconds').replace('+00:00', 'Z')}
    descriptor = os.open(destination / 'Verification.json', os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, 'w', encoding='utf-8') as output:
        json.dump(report, output, ensure_ascii=False, indent=2, allow_nan=False)
        output.flush()
        os.fsync(output.fileno())
    print(destination)
    return report

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', type=pathlib.Path, default=pathlib.Path.home() / 'Library/Application Support/GaoSeries/GaoJieTu')
    parser.add_argument('--destination', type=pathlib.Path)
    parser.add_argument('--allow-missing-root', action='store_true', help='明确接受自建隔离测试或首次安装尚未创建资料目录；已有安装禁止自动采用')
    args = parser.parse_args()
    destination = args.destination or args.root.parent / 'GaoJieTu-Backups' / ('Backup-' + datetime.datetime.now().strftime('%Y%m%d-%H%M%S') + '-' + uuid.uuid4().hex[:8] + '.noindex')
    try:
        installed = pathlib.Path('/Applications/搞截图.app')
        # lexists preserves the difference between a missing installation and a broken installed link.
        first_install = not os.path.lexists(installed)
        backup(args.root, destination, allow_missing=args.allow_missing_root or first_install)
    except (OSError, ValueError, BackupError) as error:
        print('备份已停止，原资料与未完成副本保留：' + str(error), file=sys.stderr)
        sys.exit(1)
