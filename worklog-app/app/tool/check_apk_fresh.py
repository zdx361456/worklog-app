# check_apk_fresh.py -- 断言某个 APK 确实是"本次构建"产出的，避免把旧包当成果交付。
#
# 背景（2026-10-13）：
#   build_apk.bat 旧版用 `if exist "%APK%" goto :haveapk` 判定成功。而
#   app-release.apk 是历史构建留下的旧文件、一直存在，所以即使本次构建失败，
#   脚本也会把旧包复制到桌面并显示"成功"——用户装上去自然看不到任何新功能。
#
#   本脚本提供一条独立、可证伪的判据：APK 的修改时间必须 >= 工程里最新源码的
#   修改时间。不满足即说明这个 APK 不是本次构建产出的。
#
# 用法: check_apk_fresh.py <apk_path> <project_dir>
# 退出码: 0 = FRESH（通过）   2 = STALE / MISSING / ERROR（不通过）
# 输出: 机器可读的 KEY=VALUE 行（供 .bat 判断，避免中文在控制台乱码）

import datetime
import os
import sys

# 扫描时跳过的目录（构建产物 / 缓存，不是源码）
SKIP_DIRS = {"build", ".gradle", ".dart_tool", ".idea", ".git"}
# 扫描时跳过的文件（机器本地文件，非源码内容）
SKIP_FILES = {"local.properties"}
# android 目录下只关心这些扩展名
ANDROID_EXT = {".kts", ".gradle", ".properties", ".xml", ".java", ".kt", ".pro"}


def _walk(root, keep):
    """遍历 root 下所有文件，跳过 SKIP_DIRS；keep 为 None 表示全部保留。"""
    if not os.path.isdir(root):
        return
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for name in filenames:
            if name in SKIP_FILES:
                continue
            if keep is not None and os.path.splitext(name)[1].lower() not in keep:
                continue
            yield os.path.join(dirpath, name)


def newest_source(project_dir):
    """返回 (mtime, path)，即工程里最新源码文件的修改时间。"""
    candidates = []
    # Dart 源码
    candidates.extend(_walk(os.path.join(project_dir, "lib"), None))
    # 资源
    candidates.extend(_walk(os.path.join(project_dir, "assets"), None))
    # Android 侧构建配置与源码
    candidates.extend(
        _walk(os.path.join(project_dir, "android"), ANDROID_EXT)
    )
    # 依赖清单
    for extra in ("pubspec.yaml", "pubspec.lock"):
        p = os.path.join(project_dir, extra)
        if os.path.isfile(p):
            candidates.append(p)

    newest = (0.0, "")
    for path in candidates:
        try:
            mtime = os.path.getmtime(path)
        except OSError:
            continue
        if mtime > newest[0]:
            newest = (mtime, path)
    return newest


def _fmt(ts):
    return datetime.datetime.fromtimestamp(ts).strftime("%Y-%m-%d %H:%M:%S")


def main():
    if len(sys.argv) < 3:
        print("RESULT=ERROR")
        print("HINT=usage: check_apk_fresh.py <apk_path> <project_dir>")
        return 2

    apk = sys.argv[1]
    project_dir = sys.argv[2]

    # [fix B1 · 2026-10-14] 目录不存在时必须判失败。
    # 旧版下 project_dir 拼错/不存在 → newest_source 返回 (0.0,"") → 第 96 行
    # `if src_mtime and ...` 因 0.0 为假而整段跳过 → 输出 FRESH/exit 0。
    # 这与本次要消灭的"把旧包当新包"是同一类缺陷（静默放行），必须堵死。
    if not os.path.isdir(project_dir):
        print("RESULT=ERROR")
        print("HINT=project_dir 不是目录: %s" % project_dir)
        return 2

    if not os.path.isfile(apk):
        print("RESULT=MISSING")
        print("APK=%s" % apk)
        return 2

    apk_mtime = os.path.getmtime(apk)
    src_mtime, src_path = newest_source(project_dir)

    print("APK=%s" % apk)
    print("APK_SIZE=%d" % os.path.getsize(apk))
    print("APK_MTIME=%s" % _fmt(apk_mtime))
    print("SRC_NEWEST=%s" % _fmt(src_mtime))
    print("SRC_PATH=%s" % src_path)

    # [fix B1 · 2026-10-14] 判据不可得 = 失败（fail-closed）。
    # 扫不到任何源码文件时 src_mtime 仍是 0.0，说明"新鲜度"这个判据根本没拿到，
    # 此时既不能说 FRESH 也不能说 STALE —— 必须显式判 ERROR 而不是放行。
    if not src_mtime:
        print("RESULT=ERROR")
        print("HINT=在 %s 下没扫到任何源码文件，无法判断新鲜度" % project_dir)
        return 2

    if apk_mtime < src_mtime:
        # 源码比安装包还新 —— 这个包不可能包含最新代码
        print("RESULT=STALE")
        return 2

    print("RESULT=FRESH")
    return 0


if __name__ == "__main__":
    sys.exit(main())
