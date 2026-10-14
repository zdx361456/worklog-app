@echo off
setlocal
title 工时记账 - 一键出 APK

rem ===========================================================================
rem  工时记账 App —— 一键出 APK（release，debug 密钥签名，装完即用）
rem
rem  为什么要你自己双击？
rem    出包的最后一步是 Dart 把代码编译成机器码，而 WorkBuddy 的沙箱从底层
rem    禁止这一步创建管道（CreateFile failed 231 / ERROR_PIPE_BUSY），
rem    所以沙箱内必然失败。你自己的终端没有这层限制。
rem
rem  ---------------------------------------------------------------------------
rem  【2026-10-13 修复一】旧版的"成功"判定是错的，会让你装上旧包
rem  ---------------------------------------------------------------------------
rem    旧逻辑：  if exist "%APK%" goto :haveapk
rem    它的意思是"只要这个文件在，就算成功"。但 app-release.apk 是以前构建
rem    留下的旧文件，它一直存在；所以即使本次构建失败（例如 :file_picker 的
rem    AAR 元数据检查报错），脚本也会把"上一次的旧包"复制到桌面并显示"成功"。
rem    你装到手机上，自然看不到任何新功能。
rem
rem    现在改成三重校验，任何一条不满足都直接判失败：
rem      (1) flutter build 的退出码必须是 0；
rem      (2) 安装包必须存在；
rem      (3) 安装包必须比工程源码新（否则它就不是本次构建产出的）。
rem
rem  ---------------------------------------------------------------------------
rem  【2026-10-13 修复二】桌面路径写死，导致用户"找不到文件"
rem  ---------------------------------------------------------------------------
rem    旧逻辑：set "DESK=%USERPROFILE%\Desktop"（再猜一个 OneDrive\Desktop）
rem    但本机的桌面被重定向到了：
rem      D:\workspace\software\installed\communication\OneDrive
rem    于是包被放进 C:\Users\ZDX\Desktop —— 那不是用户看到的桌面。
rem    现在改为：用 desktop_path.py 向注册表要真实桌面路径。
rem
rem  ---------------------------------------------------------------------------
rem  【2026-10-14 修复三】辅助脚本"软依赖"会静默退回旧 bug（独立复核 B2）
rem  ---------------------------------------------------------------------------
rem    旧逻辑：if exist "%DESKPY%" ...  缺了就静默退回 %USERPROFILE%\Desktop
rem    也就是：只要那个 .py 不在，这次修的"桌面定位"就原样复发，而且一声不吭。
rem    现在改为硬依赖：缺任何一个辅助件，立刻停下来并说明原因，绝不降级。
rem
rem  ---------------------------------------------------------------------------
rem  【2026-10-14 修复四】不再"听工具自述"，一切判定基于产物
rem  ---------------------------------------------------------------------------
rem    flutter pub get 的退出码此前被忽略 —— 现已纳入判定。
rem    check_apk_fresh.py 补了 fail-closed：扫不到源码 = 失败，而不是"通过"。
rem    复制结果也不再信 copy 的退出码（已整体搬进 publish_apk.py 用字节数+SHA256 校验）。
rem
rem  ---------------------------------------------------------------------------
rem  【2026-10-14 修复五】交付位置：工程内 release\ 目录 + 版本轮换
rem  ---------------------------------------------------------------------------
rem    主位置（唯一权威）：
rem      <工程>\release\worklog-release-latest.apk       <- 永远是最新那一版
rem    每次重新生成时，上一版会被自动重命名成：
rem      <工程>\release\worklog-release-<被替换时间>-replaced.apk
rem    历史只增不删、不会丢。桌面另投一份【固定名】worklog-release-latest.apk，
rem    覆盖式更新（不带时间戳 —— 否则每构建一次就多出 55MB，还要被 OneDrive 同步上传）。
rem    交付逻辑整体在 publish_apk.py 里（可单独跑自测），bat 只负责调用与判定。
rem
rem  ---------------------------------------------------------------------------
rem  【2026-10-14 修复六】★ 脚本一启动就报错退出：变量全是空的
rem  ---------------------------------------------------------------------------
rem    现象：双击后黑窗口一闪 / 停住，日志被清空但一行输出都没有，
rem          提示「找不到或无法运行桌面解析脚本」。
rem
rem    根因（本机实测复现，非猜测）：下面这种写法在 cmd 里取不到值 ——
rem        for /f "usebackq delims=" %%D in (`"%PY%" "%DESKPY%"`) do set "DESK_REG=%%D"
rem    cmd 执行 for /f 的反引号命令时，会先做一次"引号剥离"：整串以引号开头
rem    又以引号结尾，就把首尾两个引号都吃掉，结果拼成一条非法命令，报
rem    「文件名、目录名或卷标语法不正确。」→ %%D 拿不到任何东西 → 变量为空。
rem    （对照实验：换成临时文件 + set /p 取同一份输出 → 正常取到值。）
rem
rem    现在改为：把脚本输出重定向到临时文件，再用 set /p 读第一行。
rem    写法朴素，但不受 cmd 引号规则影响。
rem
rem  ---------------------------------------------------------------------------
rem  【2026-10-14 修复七】不再只能靠人肉看黑窗口
rem  ---------------------------------------------------------------------------
rem    新增全程轨迹日志 trace.log：每过一个关键步骤就追加一行。
rem    以后无论哪里失败，把 trace.log 发出来就能直接定位，不用用户复述屏幕。
rem ===========================================================================

rem ---- 固定路径（一律用反斜杠，避免混用带来的解析差异）------------------------
set "PY=C:\Users\ZDX\.workbuddy\binaries\python\versions\3.13.12\python.exe"
set "FLUTTER_VER=3.47.4"
set "SDK=D:\workspace\software\installed\tools\FlyEnv-Data\app\flutter\%FLUTTER_VER%"
set "ANDROID_HOME=D:\workspace\software\installed\tools\Android"
set "ANDROID_SDK_ROOT=%ANDROID_HOME%"
set "JAVA_HOME=D:\workspace\software\installed\tools\FlyEnv-Data\env\java"
set "PROJ=C:\Users\ZDX\WorkBuddy\2026-09-30-11-23-00\worklog-app\app"
set "TOOL=%PROJ%\tool"
set "OUT=C:\Users\ZDX\WorkBuddy\2026-09-30-11-23-00\_scratch\_build"
set "PATH=%SDK%\bin;%JAVA_HOME%\bin;%ANDROID_HOME%\platform-tools;%PATH%"

set "TEE=%TOOL%\tee_run.py"
set "CHK=%TOOL%\check_apk_fresh.py"
set "DESKPY=%TOOL%\desktop_path.py"
set "PYPY=%TOOL%\stamp.py"
set "PUB=%TOOL%\publish_apk.py"

if not exist "%OUT%" mkdir "%OUT%"
set "LOG=%OUT%\build.log"
set "REPORT=%OUT%\publish_report.txt"
set "TRACE=%OUT%\trace.log"
set "TMPD=%OUT%\_deskpath.tmp"
set "TMPS=%OUT%\_stamp.tmp"
set "APK=%PROJ%\build\app\outputs\flutter-apk\app-release.apk"
set "REL=%PROJ%\release"
set "LATEST=%REL%\worklog-release-latest.apk"

> "%TRACE%" echo [%DATE% %TIME%] ===== 出包开始 =====
>> "%TRACE%" echo [%DATE% %TIME%] STEP 路径已设置
>> "%TRACE%" echo     PY     = %PY%
>> "%TRACE%" echo     SDK    = %SDK%
>> "%TRACE%" echo     PROJ   = %PROJ%
>> "%TRACE%" echo     OUT    = %OUT%

rem ---- 前置检查：辅助件全部是硬依赖，缺任何一个立即失败并说明原因 -------------
rem [修复三] 这里刻意不用 if exist 包着后续逻辑，而是缺了就 goto 失败。
rem          判据拿不到就要失败，绝不静默降级。
if not exist "%SDK%\bin\flutter.bat" goto :nofly
if not exist "%PY%" goto :nopy
if not exist "%TEE%" goto :notee
if not exist "%CHK%" goto :nochk
if not exist "%DESKPY%" goto :nodepdesk
if not exist "%PYPY%" goto :nodepstamp
if not exist "%PUB%" goto :nodepub
>> "%TRACE%" echo [%DATE% %TIME%] STEP 前置检查通过（7 个辅助件齐全）

type nul > "%LOG%"
>> "%TRACE%" echo [%DATE% %TIME%] STEP 已清空构建日志

rem ---- 解析真实桌面路径（注册表优先；两位候选都投递，由 publish_apk.py 去重）--
rem [修复六] 原写法 for /f + 引号命令 在 cmd 里取不到值，改为 临时文件 + set /p
set "DESK_REG="
"%PY%" "%DESKPY%" > "%TMPD%" 2>> "%TRACE%"
set /p DESK_REG=<"%TMPD%"
set "DESK_ALT=%USERPROFILE%\Desktop"
>> "%TRACE%" echo [%DATE% %TIME%] STEP DESK_REG=[%DESK_REG%]  DESK_ALT=[%DESK_ALT%]
if not defined DESK_REG goto :nodepdesk

rem ---- 构建时间戳（给交付件命名用）--------------------------------------------
set "STAMP="
"%PY%" "%PYPY%" > "%TMPS%" 2>> "%TRACE%"
set /p STAMP=<"%TMPS%"
>> "%TRACE%" echo [%DATE% %TIME%] STEP STAMP=[%STAMP%]
if not defined STAMP goto :nodepstamp

echo.
echo ==========================================================
echo   工时记账 —— 正在生成安卓安装包 (release)
echo ----------------------------------------------------------
echo   全程会滚动显示进度，本窗口请勿关闭
echo   首次约 5~20 分钟；以后重建 1~3 分钟
echo ==========================================================
echo   发布目录       = %REL%
echo   最新包         = worklog-release-latest.apk
echo   桌面(注册表)   = %DESK_REG%
echo   桌面(用户目录) = %DESK_ALT%
echo   本次构建时间戳 = %STAMP%
echo   过程轨迹       = %TRACE%
echo ==========================================================
echo.

cd /d "%PROJ%"
if errorlevel 1 goto :noproj
>> "%TRACE%" echo [%DATE% %TIME%] STEP 已进入工程目录

rem ---- [1/3] 准备依赖 ---------------------------------------------------------
echo [1/3] 准备依赖 (flutter pub get) ...
>> "%TRACE%" echo [%DATE% %TIME%] STEP pub get 开始
"%PY%" "%TEE%" "%LOG%" "%SDK%\bin\flutter.bat" pub get
rem [修复四] pub get 的退出码此前被忽略。依赖没拉下来就该当场失败，
rem         而不是带着残缺依赖去编译，再让编译的报错把人带偏。
set "PUBRC=%ERRORLEVEL%"
>> "%TRACE%" echo [%DATE% %TIME%] STEP pub get 结束 exit=%PUBRC%
if not "%PUBRC%"=="0" goto :pubfailed
echo.

rem ---- [2/3] 编译（失败自动重试一次）-----------------------------------------
echo [2/3] 编译安装包 (flutter build apk --release) ...
echo       这一步最慢，刷屏是正常的，请耐心等 ...
echo.
call :build_once
if "%OK%"=="1" goto :haveapk

echo.
echo       第一次没有成功，10 秒后自动重试一次 ...
>> "%TRACE%" echo [%DATE% %TIME%] STEP 首次编译未通过，10 秒后重试
timeout /t 10 /nobreak >nul
call :build_once
if "%OK%"=="1" goto :haveapk
goto :failed

rem ---- [3/3] 发布 ------------------------------------------------------------
:haveapk
echo.
echo [3/3] 发布安装包（工程内 release\ + 版本轮换 + 桌面副本）...
echo.
>> "%TRACE%" echo [%DATE% %TIME%] STEP 发布开始
"%PY%" "%PUB%" "%APK%" "%REL%" "%STAMP%" --desk "%DESK_REG%" --desk "%DESK_ALT%" --report "%REPORT%"
set "DELRC=%ERRORLEVEL%"
>> "%TRACE%" echo [%DATE% %TIME%] STEP 发布结束 exit=%DELRC%
if not "%DELRC%"=="0" goto :deliver_failed

echo.
echo ==========================================================
echo    【成功】安装包已就位
echo ==========================================================
echo.
echo    最新安装包（唯一权威位置）：
echo      %LATEST%
echo.
echo    ---- 本次投递明细（OK=已投到；SKIP=该位置不存在；FAIL=投递失败）----
rem [修复六 · 独立复核 F-N6] 把 publish 的投递结果回显到成功横幅里。
rem   否则桌面副本失败（RESULT=OK_WITH_WARNINGS）时，用户只会看到"成功"两个大字。
findstr /b "RESULT= DESK_" "%REPORT%"
echo.
echo    怎么装到手机上：
echo      1) 手机用数据线连电脑，把这个文件拷进手机，在手机上点开安装；
echo         或直接用 adb 安装（本机已装 platform-tools）。
echo      2) 手机若提示未知来源应用，允许一次即可。
echo.
echo    上面已经打印了 SHA256，请确认是刚刚生成的包
echo ==========================================================
echo.
echo ---- release 目录当前内容（新在前）----
dir /b /o-d "%REL%"
echo.
echo ---- 本次发布明细：%REPORT%
goto :tail

:deliver_failed
echo.
echo ==========================================================
echo    【失败】构建成功了，但"发布/取件"这一步失败
echo    详细记录：%REPORT%
echo    构建输出日志：%LOG%
echo    过程轨迹：%TRACE%
echo    把这两个文件发给 WorkBuddy，我就能定位原因。
echo ==========================================================
goto :tail

:failed
echo.
echo ==========================================================
echo    【失败】没有生成新的安装包，最后退出码 = %RC%
echo.
echo    重要：%REL% 下面那些 worklog-release-*.apk 都是以前构建
echo          留下的旧包，不包含这次的最新改动，请不要安装它们
echo          （装了也看不出任何变化）。
echo.
echo    构建输出日志：%LOG%
echo    过程轨迹：%TRACE%
echo    把这两个文件发给 WorkBuddy，我就能定位原因。
echo ==========================================================
echo.
echo    ---- 现有安装包（仅供参考，请勿安装）----
if exist "%REL%\*.apk" dir /b /o-d "%REL%\*.apk"
goto :tail

rem ===========================================================================
rem  子过程：编译一次 + 三重校验（成功时置 OK=1）
rem ===========================================================================
:build_once
set "OK=0"
>> "%TRACE%" echo [%DATE% %TIME%] STEP flutter build 开始
"%PY%" "%TEE%" "%LOG%" "%SDK%\bin\flutter.bat" build apk --release
set "RC=%ERRORLEVEL%"
>> "%TRACE%" echo [%DATE% %TIME%] STEP flutter build 结束 exit=%RC%
echo.
echo       ---- 校验 1/3：flutter build 退出码 ----
echo       exit=%RC%
if not "%RC%"=="0" goto :build_rc_bad
echo       ---- 校验 2/3：安装包是否存在 ----
if not exist "%APK%" goto :build_missing
echo       ---- 校验 3/3：安装包是否比工程源码新 ----
"%PY%" "%CHK%" "%APK%" "%PROJ%"
set "VRC=%ERRORLEVEL%"
>> "%TRACE%" echo [%DATE% %TIME%] STEP 新鲜度校验 exit=%VRC%
if not "%VRC%"=="0" goto :build_stale
set "OK=1"
goto :eof

:build_rc_bad
echo       [X] 构建失败：退出码 %RC% 不为 0（编译没通过）
>> "%TRACE%" echo [%DATE% %TIME%] FAIL 构建退出码非 0
goto :eof

:build_missing
echo       [X] 构建失败：没有生成 %APK%
>> "%TRACE%" echo [%DATE% %TIME%] FAIL 安装包不存在
goto :eof

:build_stale
echo       [X] 校验不通过：这个安装包不是本次构建产出的（是旧包）
echo           （源码比安装包还新，说明安装包没有被本次构建重新生成）
>> "%TRACE%" echo [%DATE% %TIME%] FAIL 安装包过旧（非本次产出）
goto :eof

rem ===========================================================================
rem  失败出口
rem ===========================================================================
:nofly
echo [错误] 找不到 Flutter SDK: %SDK%\bin\flutter.bat
>> "%TRACE%" echo [%DATE% %TIME%] FAIL 找不到 flutter.bat
goto :tail
:nopy
echo [错误] 找不到 Python: %PY%
>> "%TRACE%" echo [%DATE% %TIME%] FAIL 找不到 python.exe
goto :tail
:notee
echo [错误] 找不到输出中继: %TEE%
>> "%TRACE%" echo [%DATE% %TIME%] FAIL 找不到 tee_run.py
goto :tail
:nochk
echo [错误] 找不到新鲜度校验脚本: %CHK%
>> "%TRACE%" echo [%DATE% %TIME%] FAIL 找不到 check_apk_fresh.py
goto :tail
:noproj
echo [错误] 进不去工程目录: %PROJ%
>> "%TRACE%" echo [%DATE% %TIME%] FAIL 进不去工程目录
goto :tail

:nodepdesk
echo [错误] 找不到或无法运行桌面解析脚本: %DESKPY%
echo        缺少它就无法确定"真实桌面"在哪（本机桌面可能被重定向到别处）。
echo        为避免把安装包放错地方，这里直接停止，不做降级处理。
echo        修复：把该文件放回 %TOOL% 后重跑本脚本。
>> "%TRACE%" echo [%DATE% %TIME%] FAIL 桌面解析失败/为空
goto :tail

:nodepstamp
echo [错误] 找不到或无法运行时间戳脚本: %PYPY%
echo        缺少它就无法给安装包生成带时间的文件名，这里直接停止。
echo        修复：把该文件放回 %TOOL% 后重跑本脚本。
>> "%TRACE%" echo [%DATE% %TIME%] FAIL 时间戳解析失败/为空
goto :tail

:nodepub
echo [错误] 找不到发布脚本: %PUB%
echo        缺少它就无法把安装包放到 release\ 目录并轮换旧版，这里直接停止。
echo        修复：把该文件放回 %TOOL% 后重跑本脚本。
>> "%TRACE%" echo [%DATE% %TIME%] FAIL 找不到 publish_apk.py
goto :tail

:pubfailed
echo [错误] 依赖准备失败（flutter pub get 退出码非 0）
echo        完整日志：%LOG%
>> "%TRACE%" echo [%DATE% %TIME%] FAIL pub get 失败
goto :tail

:tail
>> "%TRACE%" echo [%DATE% %TIME%] ===== 出包结束 =====
echo.
echo 日志文件：%LOG%
echo 发布明细：%REPORT%
echo 过程轨迹：%TRACE%
echo.
pause
endlocal
