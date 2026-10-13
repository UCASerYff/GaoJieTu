#!/bin/bash
# Only this app's fixed installation path; no launch, TCC changes, or other-app removal.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ $# -ne 0 ]]; then echo '用法：Scripts/install.sh' >&2; exit 2; fi
python3 - <<'PY'
import ctypes
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
SOURCE = project / '.build/搞截图.app'
TARGET = pathlib.Path('/Applications/搞截图.app')
DATA = pathlib.Path.home() / 'Library/Application Support/GaoSeries/GaoJieTu'
BACKUP_ROOT = DATA.parent / 'GaoJieTu-Backups'
LOCK = TARGET.parent / '.GaoJieTu-install.lock'
LSREGISTER = '/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'

def require(value, message):
    if not value:
        raise RuntimeError(message)

def strict_stat(path):
    try:
        return path.lstat()
    except FileNotFoundError:
        return None

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
    entry = strict_stat(path)
    require(entry is not None and stat.S_ISDIR(entry.st_mode) and not stat.S_ISLNK(entry.st_mode), '应用包缺失、不是目录或为链接')
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
    require(info.get('CFBundleIdentifier') == BUNDLE_ID and info.get('CFBundleExecutable') == 'GaoJieTu', '应用 Bundle ID 或可执行名称不匹配')
    validation = subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(path)], capture_output=True)
    if require_signature:
        require(validation.returncode == 0, '应用签名校验失败；尚未认可该程序')
    return info

def bundle_version(info):
    return tuple(info.get(key) for key in ('CFBundleIdentifier', 'CFBundleExecutable', 'CFBundleShortVersionString', 'CFBundleVersion'))

def require_stopped():
    result = subprocess.run(['/usr/bin/pgrep', '-x', 'GaoJieTu'], capture_output=True)
    require(result.returncode == 1, '搞截图仍在运行或无法核验进程状态；请正常退出后再安装')

def move_exclusive(source, destination):
    # Public Darwin API; RENAME_EXCL (sys/stdio.h) atomically refuses a concurrently created target.
    library = ctypes.CDLL('/usr/lib/libSystem.B.dylib', use_errno=True)
    rename = library.renamex_np
    rename.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
    rename.restype = ctypes.c_int
    if rename(os.fsencode(source), os.fsencode(destination), 0x00000004) != 0:
        code = ctypes.get_errno()
        raise OSError(code, os.strerror(code))

def register(path):
    return subprocess.run([LSREGISTER, '-f', str(path)], capture_output=True).returncode == 0

def unregister(path):
    return subprocess.run([LSREGISTER, '-u', str(path)], capture_output=True).returncode == 0

def update_pointer(backup):
    directory = project / 'TestResults'
    parent = safety.directory_fd(directory, create=True)
    temporary = 'LatestInstallationBackup-' + uuid.uuid4().hex + '.tmp'
    temporary_owned = False
    try:
        try:
            existing = os.stat('LatestInstallationBackup.txt', dir_fd=parent, follow_symlinks=False)
        except FileNotFoundError:
            existing = None
        if existing is not None:
            require(stat.S_ISREG(existing.st_mode) and existing.st_nlink == 1 and existing.st_uid == os.getuid(), '安装备份指针为链接或不安全对象')
        descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600, dir_fd=parent)
        temporary_owned = True
        with os.fdopen(descriptor, 'wb') as stream:
            stream.write((str(backup) + '\n').encode('utf-8'))
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, 'LatestInstallationBackup.txt', src_dir_fd=parent, dst_dir_fd=parent)
        temporary_owned = False
        os.fsync(parent)
    finally:
        if temporary_owned:
            os.unlink(temporary, dir_fd=parent)
        os.close(parent)

lock = AppMutationLock()
stage = None
stage_owned = False
backup = None
old_moved = False
old_ever_moved = False
new_installed = False
try:
    lock.acquire()
    require_stopped()
    source_info = verify_bundle(SOURCE)
    previous_identity = strict_stat(TARGET)
    had_previous = previous_identity is not None
    previous_info = verify_bundle(TARGET) if had_previous else None
    backup = BACKUP_ROOT / ('Backup-' + datetime.datetime.now().strftime('%Y%m%d-%H%M%S') + '-' + uuid.uuid4().hex[:8])
    safety.backup(DATA, backup, allow_missing=not had_previous)
    write_new_json(backup / 'Installation.json', {'schemaVersion': 1, 'bundleID': BUNDLE_ID, 'targetPath': str(TARGET),
        'hadPreviousApp': had_previous, 'createdAt': utc_now(),
        'sourceVersion': source_info.get('CFBundleShortVersionString'), 'sourceBuild': source_info.get('CFBundleVersion'),
        'previousVersion': previous_info.get('CFBundleShortVersionString') if previous_info else None,
        'previousBuild': previous_info.get('CFBundleVersion') if previous_info else None})
    if had_previous:
        subprocess.run(['/usr/bin/ditto', str(TARGET), str(backup / 'Previous.app')], check=True, capture_output=True)
        require(bundle_version(verify_bundle(backup / 'Previous.app')) == bundle_version(previous_info), '旧程序备份身份或版本核对失败')
    stage = TARGET.parent / ('.GaoJieTu-stage-' + uuid.uuid4().hex + '.app')
    os.mkdir(stage, 0o700)
    stage_owned = True
    subprocess.run(['/usr/bin/ditto', str(SOURCE), str(stage)], check=True, capture_output=True)
    require(bundle_version(verify_bundle(stage)) == bundle_version(source_info), '暂存程序的 Bundle ID、版本或构建与候选不一致')
    require_stopped()
    current = strict_stat(TARGET)
    if had_previous:
        require(current is not None and safety.signature(current) == safety.signature(previous_identity), '安装目标在备份后改变；停止替换')
        require(bundle_version(verify_bundle(TARGET)) == bundle_version(previous_info), '旧程序在替换前改变')
        move_exclusive(TARGET, backup / 'PreviousInstalled.app')
        old_moved = True
        old_ever_moved = True
    else:
        require(current is None, '首次安装目标被其他进程创建；停止覆盖')
    move_exclusive(stage, TARGET)
    stage_owned = False
    new_installed = True
    require(bundle_version(verify_bundle(TARGET)) == bundle_version(source_info), '安装后程序身份核验失败')
    require(register(TARGET), '本应用精确系统登记失败')
    update_pointer(backup)
    write_new_json(backup / 'InstallationCompleted.json', {'schemaVersion': 1, 'bundleID': BUNDLE_ID,
        'createdAt': utc_now(), 'installed': True, 'guiAcceptance': 'pending', 'userData': 'untouched', 'keychain': 'untouched'})
    print('安装完成；尚未启动。旧程序、安全备份与恢复材料保留至实际 GUI 验收成功。')
except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
    rollback_error = None
    try:
        if new_installed:
            # This target was installed by this invocation. A different/replaced bundle is never moved.
            require(bundle_version(verify_bundle(TARGET, require_signature=False)) == bundle_version(source_info), '失败后的安装目标发生变化，未移动未知程序')
            unregister(TARGET)
            move_exclusive(TARGET, backup / ('FailedNew-' + uuid.uuid4().hex + '.app'))
            new_installed = False
        if old_moved:
            require(strict_stat(TARGET) is None, '恢复目标被其他进程创建；旧程序保留在安全备份')
            move_exclusive(backup / 'PreviousInstalled.app', TARGET)
            old_moved = False
            verify_bundle(TARGET)
            require(register(TARGET), '旧程序已恢复但精确登记失败')
        if backup is not None and strict_stat(backup) is not None:
            write_new_json(backup / ('InstallationFailed-' + uuid.uuid4().hex + '.json'), {'schemaVersion': 1, 'bundleID': BUNDLE_ID,
                'createdAt': utc_now(), 'failed': True, 'previousRestored': old_ever_moved and not old_moved,
                'previousRetained': had_previous and not old_ever_moved,
                'userData': 'untouched', 'keychain': 'untouched', 'reason': str(error)})
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as recovery_error:
        rollback_error = recovery_error
    print('安装失败：' + str(error) + '。用户资料、安全备份与失败材料保留。', file=sys.stderr)
    if rollback_error:
        print('自动回滚需核验：' + str(rollback_error), file=sys.stderr)
    sys.exit(1)
finally:
    if stage_owned and stage is not None:
        entry = strict_stat(stage)
        if entry is not None and stat.S_ISDIR(entry.st_mode) and not stat.S_ISLNK(entry.st_mode) and entry.st_uid == os.getuid():
            shutil.rmtree(stage)
    try:
        lock.release()
    except (OSError, ValueError, RuntimeError) as error:
        print('安装锁未清理：' + str(error) + '。请核验该应用锁，不要清理其他任务。', file=sys.stderr)
        sys.exit(1)
PY
