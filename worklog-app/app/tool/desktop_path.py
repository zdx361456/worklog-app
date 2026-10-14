# desktop_path.py -- 打印「本机真实桌面路径」（供 build_apk.bat 取用）
#
# 为什么不用 reg.exe：
#   1) 本机 WorkBuddy 沙箱把 reg.exe 列入程序黑名单，无法实测验证；
#   2) 本机桌面被重定向到 OneDrive，硬编码 %USERPROFILE%\Desktop 会放错地方
#      （2026-10-13 事故：APK 被放进 C://Users//ZDX//Desktop，用户在那里找不到）。
# python 的 winreg 是标准库、无需外部程序，且可直接单测。
import os
import sys

import winreg

VALUE = 'Desktop'
# [fix A11 · 2026-10-14] 优先读 "User Shell Folders"（系统权威、可能含 %VAR% 需展开），
# 再退回 "Shell Folders"（已是展开后的静态副本）。本机两者一致，但其他机器不一定。
SUBKEYS = [
    r'Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders',
    r'Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders',
]


def main():
    path = ''
    for subkey in SUBKEYS:
        for hive in (winreg.HKEY_CURRENT_USER, winreg.HKEY_LOCAL_MACHINE):
            try:
                with winreg.OpenKey(hive, subkey) as key:
                    path = winreg.QueryValueEx(key, VALUE)[0]
            except OSError:
                continue
            if path:
                break
        if path:
            break
    if path:
        # User Shell Folders 里可能是 %USERPROFILE%\Desktop 这种未展开形式
        path = os.path.expandvars(path)
    if not path:
        path = os.path.join(os.environ.get('USERPROFILE', ''), 'Desktop')
    sys.stdout.write(path)
    return 0


if __name__ == '__main__':
    sys.exit(main())
