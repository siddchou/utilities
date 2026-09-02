@echo off
setlocal

REM --- Start the LiteLLM proxy from config.yaml ---
REM Double-click to run. Optional: pass a port as the 1st arg, e.g. start_litellm.bat 4001

cd /d "%~dp0"

set HOST=127.0.0.1
if "%~1"=="" (set PORT=4000) else (set PORT=%~1)

echo Starting LiteLLM proxy on http://%HOST%:%PORT%/v1
echo Config: %~dp0config.yaml
echo Press Ctrl+C to stop.
echo.

litellm --config config.yaml --host %HOST% --port %PORT%

echo.
echo LiteLLM stopped.
pause
