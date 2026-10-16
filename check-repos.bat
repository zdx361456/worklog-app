@echo off
rem ===========================================================================
rem  check-repos.bat —— 双击即可巡检双仓（只读，不改任何东西）
rem      本地巡检：      check-repos.bat
rem      含在线可见性：  check-repos.bat --online
rem ===========================================================================
setlocal
set "BASH="
if exist "%ProgramFiles%\Git\bin\bash.exe"                     set "BASH=%ProgramFiles%\Git\bin\bash.exe"
if not defined BASH if exist "%ProgramFiles(x86)%\Git\bin\bash.exe"    set "BASH=%ProgramFiles(x86)%\Git\bin\bash.exe"
if not defined BASH if exist "%LOCALAPPDATA%\Programs\Git\bin\bash.exe" set "BASH=%LOCALAPPDATA%\Programs\Git\bin\bash.exe"
if not defined BASH if exist "D:\workspace\software\installed\communication\WorkBuddy\resources\vendor\PortableGit\bin\bash.exe" set "BASH=D:\workspace\software\installed\communication\WorkBuddy\resources\vendor\PortableGit\bin\bash.exe"

if not defined BASH (
  echo [X] 没找到 Git Bash。
  pause
  exit /b 1
)

"%BASH%" "%~dp0tool\check-repos.sh" %*
set "RC=%ERRORLEVEL%"
echo.
if not "%RC%"=="0" echo [!] 有需要处理的项，见上面标 [X] / [!] 的行。
pause
exit /b %RC%
