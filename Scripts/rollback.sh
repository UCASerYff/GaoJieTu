#!/bin/bash
# This script changes only this app's installed bundle. User data and all backups remain untouched.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "${1:-}" != "" && "${1:-}" != "--verify-only" ]]; then echo '用法：Scripts/rollback.sh [--verify-only]' >&2; exit 2; fi
if pgrep -x GaoJieTu >/dev/null; then echo '请先正常退出搞截图，再执行回滚。' >&2; exit 1; fi
python3 - "${1:-}" <<'PY'
import datetime
import importlib.util
import json
import os
import pathlib
import plistlib
import shutil
import stat
import subprocess
import sys
import uuid

sys.dont_write_bytecode = True
project = pathlib.Path.cwd()
spec = importlib.util.spec_from_file_location('gao_backup', project / 'Scripts/backup.py')
safety = importlib.util.module_from_spec(spec)
spec.loader.exec_module(safety)
BUNDLE_ID = 'com.gaoseries.GaoJieTu'
TARGET = pathlib.Path('/Applications/搞截图.app')
DATA = pathlib.Path.home() / 'Library/Application Support/GaoSeries/GaoJieTu'
BACKUP_ROOT = DATA.parent / 'GaoJieTu-Backups'
LOCK = TARGET.parent / '.GaoJieTu-install.lock'
LSREGISTER = '/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'
verify_only = sys.argv[1] == '--verify-only'

def require(value, message):
    if not value:
        raise RuntimeError(message)

def read_private_json(path, maximum=16_777_216):
    raw = safety.regular_bytes(path.parent, path.name, maximum)
    value = json.loads(raw, object_pairs_hook=safety.unique_pairs)
    require(isinstance(value, dict), '回滚凭据不是 JSON 对象')
    return value

def exists(path):
    # Unlike Path.exists(), EACCES is not converted into a missing object.
    try:
        return path.lstat()
    except FileNotFoundError:
        return None

strict_stat = exists

def utc_now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat(timespec='seconds').replace('+00:00', 'Z')

def write_new_json(path, value):
    data = json.dumps(value, ensure_ascii=False, indent=2, allow_nan=False).encode('utf-8')
    parent = safety.directory_fd(path.parent)
    descriptor = None
    try:
        descriptor = os.open(path.name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600, dir_fd=parent)
        with os.fdopen(descriptor, 'wb') as stream:
            descriptor = None
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.fsync(parent)
    finally:
        if descriptor is not None:
            os.close(descriptor)
        os.close(parent)

class AppMutationLock:
    """Shared install/rollback protocol. Existing locks are never guessed stale or removed automatically."""
    def __init__(self):
        self.identity = None
        self.token = uuid.uuid4().hex
    def acquire(self):
        os.mkdir(LOCK, 0o700)
        entry = LOCK.lstat()
        self.identity = (entry.st_dev, entry.st_ino)
        write_new_json(LOCK / 'Owner.json', {'schemaVersion': 1, 'bundleID': BUNDLE_ID,
            'pid': os.getpid(), 'token': self.token, 'createdAt': utc_now()})
    def release(self):
        if self.identity is None:
            return
        entry = strict_stat(LOCK)
        require(entry is not None and stat.S_ISDIR(entry.st_mode) and not stat.S_ISLNK(entry.st_mode) and
                (entry.st_dev, entry.st_ino) == self.identity and entry.st_uid == os.getuid(), '安装锁身份发生变化，未清理未知对象')
        owner = json.loads(safety.regular_bytes(LOCK, 'Owner.json', 8192), object_pairs_hook=safety.unique_pairs)
        require(owner.get('bundleID') == BUNDLE_ID and owner.get('token') == self.token and owner.get('pid') == os.getpid(),
                '安装锁所有者发生变化，未删除其他任务锁')
        (LOCK / 'Owner.json').unlink()
        LOCK.rmdir()
        self.identity = None

def verify_bundle(path, *, require_signature=True):
    entry = exists(path)
    require(entry is not None and stat.S_ISDIR(entry.st_mode) and not stat.S_ISLNK(entry.st_mode), '应用包缺失、不是目录或为链接，停止回滚')
    parent = safety.directory_fd(path / 'Contents')
    descriptor = None
    try:
        descriptor = os.open('Info.plist', safety.O_FLAGS, dir_fd=parent)
        before = os.fstat(descriptor)
        require(stat.S_ISREG(before.st_mode) and before.st_nlink == 1 and before.st_uid in (0, os.getuid()) and before.st_size <= 1_048_576,
                '应用 Info.plist 不是可信的独立普通文件')
        raw = bytearray()
        while True:
            chunk = os.read(descriptor, 65536)
            if not chunk:
                break
            raw.extend(chunk)
            require(len(raw) <= 1_048_576, '应用 Info.plist 超出安全大小')
        require(safety.signature(before) == safety.signature(os.fstat(descriptor)), '应用身份在读取过程中改变')
    finally:
        if descriptor is not None:
            os.close(descriptor)
        os.close(parent)
    info = plistlib.loads(raw)
    require(info.get('CFBundleIdentifier') == BUNDLE_ID, '应用 Bundle ID 不匹配，停止回滚')
    validation = subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(path)], capture_output=True)
    if require_signature:
        require(validation.returncode == 0, '旧程序签名校验失败，停止回滚；原程序与资料保留')
    info['_rollbackSignatureValid'] = validation.returncode == 0
    return info

def register(path):
    return subprocess.run([LSREGISTER, '-f', str(path)], capture_output=True).returncode == 0

def unregister(path):
    # Exact path only. Never reset LaunchServices or any other app's registration.
    return subprocess.run([LSREGISTER, '-u', str(path)], capture_output=True).returncode == 0

def write_report(backup, value):
    path = backup / ('Rollback-' + uuid.uuid4().hex + '.json')
    data = json.dumps(value, ensure_ascii=False, indent=2, allow_nan=False).encode('utf-8')
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'wb') as stream:
        stream.write(data)
        stream.flush()
        os.fsync(stream.fileno())

lock = AppMutationLock()
try:
    lock.acquire()
    pointer = safety.regular_bytes(project / 'TestResults', 'LatestInstallationBackup.txt', 8192).decode('utf-8')
    require(pointer.endswith('\n') and pointer.count('\n') == 1 and '\r' not in pointer and '\0' not in pointer,
            '安装备份指针格式损坏，停止回滚')
    backup = pathlib.Path(pointer[:-1])
    require(backup.is_absolute() and '..' not in backup.parts and backup.parent == BACKUP_ROOT and backup.name.startswith('Backup-'),
            '安装备份指针不在本应用专用备份目录内')
    fd = safety.directory_fd(backup)
    os.close(fd)
    verification = read_private_json(backup / 'Verification.json')
    require(type(verification.get('schemaVersion')) is int and verification['schemaVersion'] == 1 and
            verification.get('verified') is True and verification.get('restoreRehearsal') is True and
            verification.get('keychain') == 'untouched' and type(verification.get('sourceExisted')) is bool,
            '备份未通过完整核验或恢复演练，停止回滚')
    files, directories, _ = safety.snapshot(backup / 'Data')
    require(files == verification.get('inventory') and directories == verification.get('directories'), '安全备份内容发生变化，停止回滚')
    safety.preflight(backup / 'Data', files, directories, logical_root=DATA)
    receipt = read_private_json(backup / 'Installation.json', 1_048_576)
    require(type(receipt.get('schemaVersion')) is int and receipt['schemaVersion'] == 1 and receipt.get('bundleID') == BUNDLE_ID and
            receipt.get('targetPath') == str(TARGET) and type(receipt.get('hadPreviousApp')) is bool,
            '安装收据缺失或不匹配；不能把旧程序缺失当作首次安装')
    had_previous = receipt['hadPreviousApp']
    prior_installed, prior_copy = backup / 'PreviousInstalled.app', backup / 'Previous.app'
    current_exists = exists(TARGET) is not None
    current_info = verify_bundle(TARGET, require_signature=False) if current_exists else None
    old = prior_installed if exists(prior_installed) is not None else prior_copy if exists(prior_copy) is not None else None
    if had_previous:
        require(old is not None, '收据说明存在旧版本，但旧程序备份缺失；未撤下当前程序')
        old_info = verify_bundle(old)
    else:
        require(old is None, '首次安装收据与旧程序备份矛盾，停止回滚')
        old_info = None
    if verify_only:
        print('回滚预检通过：' + ('可恢复已签名旧程序。' if had_previous else '确认为首次安装；执行时仅撤下失败新程序并保留其备份。'))
        sys.exit(0)
    stage = TARGET.parent / ('.GaoJieTu-rollback-' + uuid.uuid4().hex + '.app')
    failed = backup / ('FailedNewRollback-' + uuid.uuid4().hex + '.app')
    require(exists(stage) is None and exists(failed) is None, '回滚暂存路径冲突')
    staged = False
    moved_current = False
    try:
        if had_previous:
            # Keep the old backup intact; stage and verify a separate copy before touching the current installation.
            subprocess.run(['/usr/bin/ditto', str(old), str(stage)], check=True, capture_output=True)
            staged = True
            verify_bundle(stage)
        if current_exists:
            require(unregister(TARGET), '无法精确注销本应用当前路径；尚未撤下程序')
            try:
                os.rename(TARGET, failed)
                moved_current = True
            except BaseException:
                register(TARGET)
                raise
        if had_previous:
            require(exists(TARGET) is None, '回滚目标被其他进程创建，停止覆盖')
            try:
                os.rename(stage, TARGET)
                staged = False
                verify_bundle(TARGET)
            except BaseException:
                # Only restore the failed app when the target is absent; never overwrite an unknown concurrent bundle.
                if exists(TARGET) is None and moved_current:
                    os.rename(failed, TARGET)
                    moved_current = False
                    register(TARGET)
                raise
            registration_ok = register(TARGET)
        else:
            registration_ok = True
        report = {'schemaVersion': 1, 'bundleID': BUNDLE_ID,
                  'createdAt': datetime.datetime.now(datetime.timezone.utc).isoformat().replace('+00:00', 'Z'),
                  'hadPreviousApp': had_previous, 'restoredPreviousApp': had_previous,
                  'failedAppPreserved': moved_current, 'data': 'untouched', 'keychain': 'untouched',
                  'withdrawnSignatureValid': current_info.get('_rollbackSignatureValid') if current_info else None,
                  'registrationVerified': registration_ok,
                  'oldVersion': old_info.get('CFBundleShortVersionString') if old_info else None,
                  'withdrawnVersion': current_info.get('CFBundleShortVersionString') if current_info else None}
        write_report(backup, report)
        print('旧程序已恢复，失败新程序已保存至安装备份；用户资料与钥匙串未改动。' if had_previous else
              '首次安装的失败新程序已撤下并保存至安装备份；用户资料与钥匙串未改动。' if moved_current else
              '首次安装程序已不在安装路径，无需再次撤下；用户资料与钥匙串未改动。')
        if not registration_ok:
            print('旧程序已恢复，但精确系统登记失败；请核验本应用登记。', file=sys.stderr)
            sys.exit(1)
    finally:
        if staged and exists(stage) is not None:
            # This random stage was created by this invocation; the original old backup remains preserved.
            shutil.rmtree(stage)
except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
    print('回滚已停止：' + str(error) + '。用户资料和安全备份未清理。', file=sys.stderr)
    sys.exit(1)
finally:
    try:
        lock.release()
    except (OSError, ValueError, RuntimeError) as error:
        print('安装锁未清理：' + str(error) + '。请核验该应用锁，不要清理其他任务。', file=sys.stderr)
        sys.exit(1)
PY
