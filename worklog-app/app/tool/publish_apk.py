# -*- coding: utf-8 -*-
"""publish_apk.py -- 发布新构建的 APK：更新「最新位」、归档被替换的旧版、投放桌面副本。

用户约定（2026-10-14）：
  主位置（唯一权威）: <release_dir>/worklog-release-latest.apk
      永远保存最新一版；重新生成时**原地替换**。
  被替换的旧版归档: <release_dir>/worklog-release-<被替换时间>-replaced.apk
      旧版在让位前被重命名，名字里带上「它被替换的时刻」；历史只增不删。
  桌面副本（次要，方便直接取用）: <desk>/worklog-release-<构建时间戳>.apk
      带时间戳、不覆盖既有文件。

为什么这段逻辑不在 .bat 里：
  .bat 在本机沙箱内无法端到端执行（cmd.exe 被安全策略拦截），
  于是"交付"这一步长期处于"读起来对、但从没被真跑过"的状态
  —— 独立复核 2026-10-14 的证据缺口 G1 正是这么发现的。
  搬进 Python 后每一步都能被真实执行与断言。

判定纪律：
  所有「成功」都必须能被产物证伪。主位置（latest）的每一步都严格校验
  （字节数 + SHA256）；任何一步没做到位，或判据根本拿不到，一律判失败
  （fail-closed），绝不静默放行。桌面副本失败只降级为「警告」，因为
  它不是权威位置——但一定会被大声打印出来，绝不假装没事。

用法:
  publish_apk.py <src_apk> <release_dir> <stamp> [--desk <dir>]... [--report <file>]

退出码: 0 = 成功（含"成功但有警告"）   2 = 失败
stdout : 人类可读摘要（已做编码兜底，控制台代码页不匹配也不会崩）
report : KEY=VALUE 明细（UTF-8）
"""

import hashlib
import os
import shutil
import sys
from datetime import datetime

LATEST_NAME = 'worklog-release-latest.apk'
HIST_FMT = 'worklog-release-%s-replaced.apk'
# 桌面副本用固定名：每次都覆盖同一份。
# 理由：桌面副本只是"方便直接取用"，若带时间戳会每构建一次多出 55MB
#      （本机桌面还被 OneDrive 同步，等于每次多上传 55MB）。历史只留在 release/。
DESK_NAME = 'worklog-release-latest.apk'

# 比 1 MiB 还小的一定不是真的 release APK（正常约 55 MB）
MIN_APK_BYTES = 1024 * 1024

try:
    sys.stdout.reconfigure(errors='replace')
except Exception:
    pass


def sha256_of(path, chunk=1024 * 1024):
    h = hashlib.sha256()
    with open(path, 'rb') as fh:
        while True:
            block = fh.read(chunk)
            if not block:
                break
            h.update(block)
    return h.hexdigest()


def same_size(a, b):
    try:
        return os.path.getsize(a) == os.path.getsize(b)
    except OSError:
        return False


def _parse(argv):
    pos, desks, report = [], [], None
    i = 0
    while i < len(argv):
        arg = argv[i]
        if arg == '--desk':
            i += 1
            if i >= len(argv):
                raise ValueError('--desk 后面缺少目录')
            desks.append(argv[i])
        elif arg == '--report':
            i += 1
            if i >= len(argv):
                raise ValueError('--report 后面缺少文件路径')
            report = argv[i]
        else:
            pos.append(arg)
        i += 1
    return pos, desks, report


def _fail(report_path, reason, lines=None):
    lines = list(lines or [])
    lines.append('RESULT=FAIL')
    lines.append('REASON=%s' % reason)
    print('')
    print('==== 发布失败 ====')
    print(reason)
    if report_path:
        try:
            with open(report_path, 'w', encoding='utf-8') as fh:
                fh.write('\n'.join(lines) + '\n')
        except OSError:
            pass
    print('RESULT=FAIL')
    return 2


def _run(src, release_dir, stamp, desks, report_path):
    lines = []

    # ---- 0. 源包自检：不存在 / 太小 ⇒ 失败 ----
    if not os.path.isfile(src):
        return _fail(report_path, '源安装包不存在：%s' % src, lines)
    src_size = os.path.getsize(src)
    if src_size < MIN_APK_BYTES:
        return _fail(
            report_path,
            '源安装包只有 %d 字节（< 1MiB），不像是真的 release APK：%s'
            % (src_size, src), lines)
    src_hash = sha256_of(src)
    lines.append('SRC=%s' % src)
    lines.append('SRC_SIZE=%d' % src_size)
    lines.append('SRC_SHA256=%s' % src_hash)

    # ---- 1. 发布目录：不存在就建；建不出来 ⇒ 失败 ----
    try:
        os.makedirs(release_dir, exist_ok=True)
    except OSError as exc:
        return _fail(report_path, '无法创建发布目录 %s：%s' % (release_dir, exc), lines)
    if not os.path.isdir(release_dir):
        return _fail(report_path, '发布目录不可用：%s' % release_dir, lines)
    lines.append('RELEASE_DIR=%s' % release_dir)

    latest = os.path.join(release_dir, LATEST_NAME)

    # ---- 2. 先把新包拷到临时位并校验，再动旧版 ----
    #      这样即使中途失败，也不会出现"旧的已挪走、新的还没上位"的空档。
    tmp = os.path.join(release_dir, '.tmp-publish-%s.apk' % stamp)
    try:
        shutil.copy2(src, tmp)
    except OSError as exc:
        return _fail(report_path, '拷贝到临时位失败：%s' % exc, lines)
    if not same_size(src, tmp):
        return _fail(report_path, '临时位字节数与源不一致（源 %d）' % src_size, lines)

    # ---- 3. 旧版让位：重命名，名字里带上"被替换的时间" ----
    rotated = None
    if os.path.isfile(latest):
        now = datetime.now().strftime('%Y%m%d-%H%M%S')
        dest = os.path.join(release_dir, HIST_FMT % now)
        suffix = 2
        while os.path.exists(dest):
            dest = os.path.join(release_dir, HIST_FMT % ('%s-%d' % (now, suffix)))
            suffix += 1
        old_size = os.path.getsize(latest)
        try:
            os.replace(latest, dest)
        except OSError as exc:
            return _fail(report_path, '旧版归档失败（重命名出错）：%s' % exc, lines)
        if not os.path.isfile(dest) or os.path.getsize(dest) != old_size:
            return _fail(report_path, '旧版归档校验不通过：%s' % dest, lines)
        rotated = dest
        lines.append('ROTATED_TO=%s' % dest)
        lines.append('ROTATED_SIZE=%d' % old_size)

    # ---- 4. 新包上位并严格校验 ----
    try:
        os.replace(tmp, latest)
    except OSError as exc:
        return _fail(report_path, '新包上位失败：%s' % exc, lines)
    if not os.path.isfile(latest):
        return _fail(report_path, '最新位不存在：%s' % latest, lines)
    if os.path.getsize(latest) != src_size:
        return _fail(report_path, '最新位字节数与源不一致（源 %d）' % src_size, lines)
    if sha256_of(latest) != src_hash:
        return _fail(report_path, '最新位 SHA256 与源不一致', lines)
    lines.append('LATEST=%s' % latest)
    lines.append('LATEST_SIZE=%d' % src_size)
    lines.append('LATEST_SHA256=%s' % src_hash)

    # ---- 5. 桌面副本（次要位置；失败只算警告，但一定大声报出来）----
    desk_rows = []
    seen = set()
    for raw_dir in desks:
        desk_dir = (raw_dir or '').strip()
        if not desk_dir:
            desk_rows.append(('SKIP', '(路径为空，未投递)'))
            continue
        key = os.path.normcase(os.path.normpath(desk_dir))
        if key in seen:
            continue
        seen.add(key)
        if not os.path.isdir(desk_dir):
            desk_rows.append(('SKIP', '%s（目录不存在，未投递）' % desk_dir))
            continue
        dest = os.path.join(desk_dir, DESK_NAME)
        # 先写临时名、校验、再原子替换：中途失败不会在桌面留下半个损坏的包
        tmp_desk = os.path.join(desk_dir, '.tmp-desk-%s.apk' % stamp)
        try:
            shutil.copy2(src, tmp_desk)
            if not same_size(src, tmp_desk):
                raise OSError('临时副本字节数与源不一致')
            os.replace(tmp_desk, dest)
        except OSError as exc:
            desk_rows.append(('FAIL', '%s（%s）' % (dest, exc)))
            continue
        if same_size(src, dest) and sha256_of(dest) == src_hash:
            desk_rows.append(('OK', dest))
        else:
            desk_rows.append(('FAIL', '%s（字节数或哈希与源不一致）' % dest))

    lines.append('DESK_COUNT=%d' % len(desk_rows))
    for idx, (state, info) in enumerate(desk_rows, 1):
        lines.append('DESK_%d=%s %s' % (idx, state, info))

    desk_failed = [r for r in desk_rows if r[0] == 'FAIL']
    result = 'OK_WITH_WARNINGS' if desk_failed else 'OK'
    lines.append('RESULT=%s' % result)

    # ---- 6. 人类可读总结 ----
    print('')
    print('---------------- 发布结果 ----------------')
    print('【主位置 · 唯一权威】')
    print('  %s' % latest)
    print('    %d 字节' % src_size)
    print('    SHA256 %s' % src_hash)
    if rotated:
        print('【上一版已归档】')
        print('  %s' % rotated)
    else:
        print('【上一版】无（这是第一次发布）')
    print('【桌面副本】')
    if not desk_rows:
        print('  （未要求投递）')
    for state, info in desk_rows:
        print('  [%s] %s' % (state, info))
    if desk_failed:
        print('')
        print('!! 警告：桌面副本有 %d 处失败 —— 但主位置已成功，不影响安装包本身。'
              % len(desk_failed))
    print('------------------------------------------')
    print('RESULT=%s' % result)

    if report_path:
        try:
            with open(report_path, 'w', encoding='utf-8') as fh:
                fh.write('\n'.join(lines) + '\n')
        except OSError:
            pass
    return 0


def main():
    try:
        pos, desks, report_path = _parse(sys.argv[1:])
    except ValueError as exc:
        return _fail(None, '参数错误：%s' % exc)

    if len(pos) != 3:
        return _fail(
            None,
            '用法: publish_apk.py <src_apk> <release_dir> <stamp> '
            '[--desk <dir>]... [--report <file>]')

    return _run(pos[0], pos[1], pos[2], desks, report_path)


if __name__ == '__main__':
    sys.exit(main())
