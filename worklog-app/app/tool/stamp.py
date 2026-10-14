# stamp.py -- 打印 yyyymmdd-HHMMSS（供 build_apk.bat / publish_apk.py 给安装包命名）
#
# [fix A10 · 2026-10-14] 由「到分钟」改为「到秒」。独立复核指出：同一分钟内重跑
# 会生成同名交付件而互相覆盖，与"不覆盖旧的"这一承诺相矛盾。
import datetime
import sys

sys.stdout.write(datetime.datetime.now().strftime('%Y%m%d-%H%M%S'))
sys.exit(0)
