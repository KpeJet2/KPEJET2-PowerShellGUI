@echo off
chcp 65001 >nul
setlocal

:: VersionTag: 2608.B1.V1.0
set "WS=%~dp0"
if "%WS:~-1%"=="\" set "WS=%WS:~0,-1%"

set "MODE=%~1"
if /I "%MODE%"=="stop" goto :stop
if /I "%MODE%"=="status" goto :status
if /I "%MODE%"=="detect" goto :detect
if /I "%MODE%"=="dry" goto :dry

pwsh -NoProfile -ExecutionPolicy Bypass -File "%WS%\scripts\Invoke-SessionResilienceLoop.ps1" -WorkspacePath "%WS%" -ResumeToday
goto :eof

:dry
pwsh -NoProfile -ExecutionPolicy Bypass -File "%WS%\scripts\Invoke-SessionResilienceLoop.ps1" -WorkspacePath "%WS%" -ResumeToday -DryRun
goto :eof

:detect
pwsh -NoProfile -ExecutionPolicy Bypass -File "%WS%\scripts\Invoke-SessionResilienceLoop.ps1" -WorkspacePath "%WS%" -DetectOnly
goto :eof

:status
pwsh -NoProfile -ExecutionPolicy Bypass -File "%WS%\scripts\Invoke-SessionResilienceLoop.ps1" -WorkspacePath "%WS%" -Status
goto :eof

:stop
pwsh -NoProfile -ExecutionPolicy Bypass -File "%WS%\scripts\Invoke-SessionResilienceLoop.ps1" -WorkspacePath "%WS%" -Stop
