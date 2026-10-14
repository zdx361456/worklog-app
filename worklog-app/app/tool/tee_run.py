# tee_run.py -- run a command, stream output live to the console AND append it to a log file.
# Usage: python tee_run.py <logfile> <exe> [args...]
# Exit code = wrapped command's exit code.
#
# [fix A5 · 2026-10-14] 解码改为「多编码回退」。
#   旧版固定按 UTF-8 解码，但本机 cmd.exe / gradle 实际以 GBK(cp936) 输出，
#   于是日志里每个中文字都变成 U+FFFD（实测注入 GBK 中文 → 17 个 '\ufffd'）。
#   而 build.log 正是出包失败时唯一要回传的诊断件，中文全丢等于诊断失效。
#   策略：先试 UTF-8（严格），失败再试本机 ANSI 代码页；全失败才 replace 兜底。
import locale
import sys
import subprocess
import datetime

# Console display keeps the console's own codepage (so Chinese renders correctly in
# cmd.exe); only undecodable bytes are replaced. The LOG is always written as UTF-8.
try:
    sys.stdout.reconfigure(errors='replace')
except Exception:
    pass

_encodings = ['utf-8']
try:
    _pref = locale.getpreferredencoding(False)
except Exception:
    _pref = None
for _e in (_pref, 'mbcs', 'cp936', 'gbk'):
    if _e and _e.lower().replace('-', '') not in [
            x.lower().replace('-', '') for x in _encodings]:
        _encodings.append(_e)


def _decode(raw):
    """多编码回退解码：子进程可能发 UTF-8，也可能发本机 ANSI 代码页。"""
    for enc in _encodings:
        try:
            return raw.decode(enc)
        except (UnicodeDecodeError, LookupError):
            continue
    return raw.decode('utf-8', errors='replace')

if len(sys.argv) < 3:
    sys.stderr.write("usage: tee_run.py <logfile> <exe> [args...]\n")
    sys.exit(2)

log_path = sys.argv[1]
cmd = sys.argv[2:]

# CreateProcess cannot start a .bat/.cmd image directly -- route it through cmd.exe.
if cmd[0].lower().endswith(('.bat', '.cmd')):
    cmd = ['cmd.exe', '/c'] + cmd

stamp = datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')

with open(log_path, 'a', encoding='utf-8', errors='replace') as lf:
    header = "---- [run] %s :: %s ----" % (stamp, ' '.join(cmd))
    print(header, flush=True)
    lf.write(header + "\n")
    lf.flush()

    try:
        proc = subprocess.Popen(cmd, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, bufsize=0)
    except OSError as exc:
        msg = "---- [run] LAUNCH FAILED: %s ----" % exc
        print(msg, flush=True)
        lf.write(msg + "\n")
        lf.flush()
        sys.exit(9009)

    for raw in iter(proc.stdout.readline, b''):
        line = _decode(raw).rstrip('\r\n')
        print(line, flush=True)
        lf.write(line + "\n")
        lf.flush()

    proc.wait()
    rc = proc.returncode

    footer = "---- [run] %s :: exit=%s ----" % (
        datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S'), rc)
    print(footer, flush=True)
    lf.write(footer + "\n")
    lf.flush()

sys.exit(rc)
