@echo off
rem ===========================================================================
rem  sync-repos.bat —— 双击即可「提交 → 推 GitHub → 推 Gitee → 校验 HEAD」
rem
rem  这个 .bat 只是一层壳：真正的逻辑在 tool\git-sync.sh（便于阅读和改）。
rem  想带提交说明就用命令行：
rem      sync-repos.bat -m "fix: 修了 xxx"
rem ===========================================================================
setlocal
set "BASH="
if exist "%ProgramFiles%\Git\bin\bash.exe"                     set "BASH=%ProgramFiles%\Git\bin\bash.exe"
if not defined BASH if exist "%ProgramFiles(x86)%\Git\bin\bash.exe"    set "BASH=%ProgramFiles(x86)%\Git\bin\bash.exe"
if not defined BASH if exist "%LOCALAPPDATA%\Programs\Git\bin\bash.exe" set "BASH=%LOCALAPPDATA%\Programs\Git\bin\bash.exe"
if not defined BASH if exist "D:\workspace\software\installed\communication\WorkBuddy\resources\vendor\PortableGit\bin\bash.exe" set "BASH=D:\workspace\software\installed\communication\WorkBuddy\resources\vendor\PortableGit\bin\bash.exe"

if not defined BASH (
  echo [X] 没找到 Git Bash。
  echo     装一个 Git for Windows，或手工跑：
  echo         bash tool\git-sync.sh -m "你的提交说明"
  pause
  exit /b 1
)

"%BASH%" "%~dp0tool\git-sync.sh" %*
set "RC=%ERRORLEVEL%"
echo.
if not "%RC%"=="0" echo [X] 退出码 %RC%
echo （窗口保持打开，看完再关）
pause
exit /b %RC%
