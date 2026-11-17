@echo off
rem ===========================================================
rem  go.cmd - double-click entry point.
rem
rem  Windows client defaults to ExecutionPolicy = Restricted,
rem  so running .\xxx.ps1 directly fails with
rem  "running scripts is disabled on this system".
rem
rem  This wrapper passes -ExecutionPolicy Bypass for the current
rem  process only. It does NOT change any system setting.
rem
rem  Usage:
rem    go.cmd                same as run.ps1
rem    go.cmd probe          same as chaoxing.ps1 probe
rem    go.cmd check          same as chaoxing.ps1 discover
rem    go.cmd status         same as chaoxing.ps1 status
rem    go.cmd start          same as chaoxing.ps1 start
rem    go.cmd login          same as login.ps1 -Platform chaoxing
rem    go.cmd verify         same as verify.ps1 -Shot
rem    go.cmd setup          same as install-deps.ps1 all
rem ===========================================================
setlocal
cd /d "%~dp0"

set "PS=powershell -NoProfile -ExecutionPolicy Bypass -File"

if "%~1"=="" (
    %PS% "%~dp0run.ps1"
    goto :end
)

if /i "%~1"=="probe"  ( %PS% "%~dp0chaoxing.ps1" probe    & goto :end )
if /i "%~1"=="check"  ( %PS% "%~dp0chaoxing.ps1" discover & goto :end )
if /i "%~1"=="status" ( %PS% "%~dp0chaoxing.ps1" status   & goto :end )
if /i "%~1"=="start"  ( %PS% "%~dp0chaoxing.ps1" start    & goto :end )
if /i "%~1"=="login"  ( %PS% "%~dp0login.ps1" -Platform chaoxing & goto :end )
if /i "%~1"=="verify" ( %PS% "%~dp0verify.ps1" -Shot     & goto :end )
if /i "%~1"=="setup"  ( %PS% "%~dp0install-deps.ps1" all & goto :end )

rem Unknown subcommand: fail loudly instead of silently running the full pipeline.
rem Args starting with "-" are passed through to run.ps1 (e.g. go.cmd -Platform zhihuishu).
set "ARG=%~1"
if "%ARG:~0,1%"=="-" ( %PS% "%~dp0run.ps1" %* & goto :end )
echo [go.cmd] Unknown command: %ARG%
echo Usage: go.cmd [probe^|check^|status^|start^|login^|verify^|setup]
echo        go.cmd -Platform ^<id^>   (pass args to run.ps1)
exit /b 1

:end
endlocal
