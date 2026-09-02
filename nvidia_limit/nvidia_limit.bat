@echo off
setlocal EnableExtensions EnableDelayedExpansion

REM ============================================================================
REM  nvidia_limit.bat - Configure NVIDIA GPU power limits on Windows
REM
REM  For every detected GPU this script will:
REM    1. Wait for the driver / nvidia-smi to be ready (with retries)
REM    2. Enable persistence mode (-pm 1)
REM    3. Set a target power limit (-pl), clamped into the GPU's min/max range
REM    4. Verify the applied limit and print a status summary
REM
REM  Usage:
REM    nvidia_limit.bat [powerLimitWatts] [waitSeconds]
REM      powerLimitWatts   Target power limit in watts (default: 275)
REM      waitSeconds       Initial delay for driver init, 0 to skip (default: 15)
REM
REM  Requires: administrator privileges and an NVIDIA driver with nvidia-smi.
REM  Exit code: 0 = all GPUs configured, 1 = one or more failures / bad usage.
REM ============================================================================

set "TARGET_W=275"
if not "%~1"=="" set "TARGET_W=%~1"
set "WAIT_S=15"
if not "%~2"=="" set "WAIT_S=%~2"

echo ============================================================================
echo  NVIDIA GPU Power Limiter
echo    Target power limit : %TARGET_W% W (all detected GPUs)
echo    Persistence mode   : ON
echo    Started            : %date% %time%
echo ============================================================================
echo.

REM ---------------------------------------------------------------------------
REM Validate arguments (non-negative integers)
REM ---------------------------------------------------------------------------
call :is_number "%TARGET_W%" || goto :bad_usage
call :is_number "%WAIT_S%" || goto :bad_usage

title NVIDIA GPU Power Limit - %TARGET_W% W

REM ---------------------------------------------------------------------------
REM Check that nvidia-smi exists (NVIDIA driver installed)
REM ---------------------------------------------------------------------------
where nvidia-smi >nul 2>&1 || (
    echo [ERROR] nvidia-smi was not found on PATH.
    echo         Install the NVIDIA GPU driver and try again.
    goto :fail
)

REM ---------------------------------------------------------------------------
REM Check for administrator privileges (-pl requires elevation).
REM  Advisory only: net session is an unreliable elevation probe (it can report
REM  failure even when elevated), so we warn and continue rather than hard-stop.
REM  If we truly lack rights, nvidia-smi -pl below will fail per-GPU with its
REM  own clear error instead of being blocked here.
REM ---------------------------------------------------------------------------
net session >nul 2>&1 || (
    echo [WARN] Could not confirm administrator privileges via "net session".
    echo        Continuing anyway - if the power limit fails, re-run elevated:
    echo        right-click the script and choose "Run as administrator".
)

REM ---------------------------------------------------------------------------
REM Wait for driver initialization, then confirm nvidia-smi can see GPUs
REM ---------------------------------------------------------------------------
if not "%WAIT_S%"=="0" (
    echo Waiting %WAIT_S%s for GPU/driver initialization...
    timeout /t %WAIT_S% /nobreak >nul
)

set "READY=0"
for /l %%r in (1,1,5) do (
    if !READY!==0 (
        nvidia-smi -L >nul 2>&1 && set "READY=1" || timeout /t 3 /nobreak >nul
    )
)
if !READY!==0 (
    echo [ERROR] nvidia-smi is not reporting any GPUs after retries.
    goto :fail
)

REM ---------------------------------------------------------------------------
REM Detect GPU count and driver version
REM ---------------------------------------------------------------------------
set "GPU_COUNT=0"
for /f %%g in ('nvidia-smi -L 2^>nul ^| findstr /r "^GPU [0-9][0-9]*:"') do set /a GPU_COUNT+=1
if %GPU_COUNT%==0 (
    echo [ERROR] No NVIDIA GPUs detected.
    goto :fail
)

set "DRV_VER=unknown"
for /f %%v in ('nvidia-smi --query-gpu=driver_version "--format=csv,noheader" 2^>nul') do set "DRV_VER=%%~v"

echo Detected %GPU_COUNT% GPU(s). Driver: !DRV_VER!
echo.

REM ---------------------------------------------------------------------------
REM Configure each GPU
REM ---------------------------------------------------------------------------
set /a OK=0 & set /a FAILS=0
set /a LAST_IDX=%GPU_COUNT%-1
for /l %%i in (0,1,%LAST_IDX%) do call :configure_gpu %%i

REM ---------------------------------------------------------------------------
REM Summary + status table
REM ---------------------------------------------------------------------------
echo.
echo ============================================================================
if %FAILS%==0 (
    echo  SUCCESS: all %OK% GPU^(s^) configured to the target power limit.
) else (
    echo  WARNING: %OK%/%GPU_COUNT% GPUs configured, %FAILS% failed - see messages above.
)
echo ============================================================================
echo.
echo Current GPU Status:
echo -------------------
nvidia-smi --query-gpu=index,name,power.limit,power.draw,temperature.gpu,utilization.gpu,memory.used --format=csv

if %FAILS%==0 (
    echo.
    pause
    endlocal & exit /b 0
)
goto :fail

REM ---------------------------------------------------------------------------
REM :configure_gpu <index> - persistence mode + power limit for one GPU
REM ---------------------------------------------------------------------------
:configure_gpu
set "IDX=%~1"
echo [GPU %IDX%] Configuring...

REM --- Read this GPU's allowed power range (watts) ---
REM  nvidia-smi has no power.limit.min/max query fields; the range only comes
REM  from the -q -d POWER section ("Min/Max Power Limit : <n>.00 W"). That
REM  block lists real values first, then repeats the labels as N/A, so we take
REM  the first match (the not-defined guard keeps it).
set "MIN_W=" & set "MAX_W="
for /f "tokens=2 delims=:." %%a in ('nvidia-smi -i %IDX% -q -d POWER 2^>nul ^| findstr /c:"Min Power Limit"') do (
    if not defined MIN_W set "MIN_W=%%~a"
)
for /f "tokens=2 delims=:." %%b in ('nvidia-smi -i %IDX% -q -d POWER 2^>nul ^| findstr /c:"Max Power Limit"') do (
    if not defined MAX_W set "MAX_W=%%~b"
)

if not defined MIN_W if not defined MAX_W (
    echo   [ERROR] Could not read the power limit range for GPU %IDX%.
    set /a FAILS+=1
    goto :eof
)

REM Convert " 100.00 W" -^> 100 (integer watts); blank out non-numeric values
set "MIN_INT=%MIN_W%" & set "MAX_INT=%MAX_W%"
for /f "tokens=1 delims=. " %%m in ("%MIN_INT%") do set "MIN_INT=%%~m"
for /f "tokens=1 delims=. " %%x in ("%MAX_INT%") do set "MAX_INT=%%~x"
call :is_number "%MIN_INT%" || set "MIN_INT="
call :is_number "%MAX_INT%" || set "MAX_INT="

REM --- Clamp target into [min, max] with a warning ---
set "APPLY_W=%TARGET_W%"
if defined MIN_INT if !APPLY_W! lss !MIN_INT! (
    echo   [WARN] %TARGET_W%W is below this GPU's minimum ^(!MIN_INT!W^); using the minimum.
    set "APPLY_W=!MIN_INT!"
)
if defined MAX_INT if !APPLY_W! gtr !MAX_INT! (
    echo   [WARN] %TARGET_W%W exceeds this GPU's maximum ^(!MAX_INT!W^); using the maximum.
    set "APPLY_W=!MAX_INT!"
)

REM --- Enable persistence mode (best-effort; not supported on all platforms) ---
nvidia-smi -pm 1 -i %IDX% >nul 2>&1 || echo   [WARN] Persistence mode could not be enabled on GPU %IDX% (continuing).

REM --- Apply power limit ---
nvidia-smi -pl !APPLY_W! -i %IDX% >nul 2>&1 || (
    echo   [ERROR] Failed to set the power limit on GPU %IDX%.
    set /a FAILS+=1
    goto :eof
)

REM --- Verify the applied limit ---
set "ACTUAL_W="
for /f "tokens=1 delims=," %%v in ('nvidia-smi -i %IDX% --query-gpu=power.limit "--format=csv,noheader,nounits" 2^>nul') do set "ACTUAL_W=%%~v"
set "ACTUAL_INT=%ACTUAL_W%"
for /f "tokens=1 delims=." %%a in ("%ACTUAL_INT%") do set "ACTUAL_INT=%%~a"

if "!ACTUAL_INT!"=="!APPLY_W!" (
    echo   [ OK ] Persistence mode ON, power limit = !ACTUAL_INT! W  ^(range !MIN_INT!-!MAX_INT! W^)
    set /a OK+=1
) else (
    echo   [FAIL] Requested !APPLY_W!W but GPU %IDX% reports !ACTUAL_INT!W.
    set /a FAILS+=1
)
goto :eof

REM ---------------------------------------------------------------------------
REM :is_number <value> - ERRORLEVEL 0 if value is a non-negative integer.
REM   Splits the value on digit characters; any surviving token means it
REM   contains a non-digit. (findstr has no end-of-line anchor, and in-place
REM   !VAR:x=! substitution misbehaves once VAR becomes empty.)
REM ---------------------------------------------------------------------------
:is_number
if "%~1"=="" exit /b 1
set "FLAG="
for /f "delims=0123456789" %%d in ("%~1") do set "FLAG=yes"
if defined FLAG exit /b 1
exit /b 0

REM ---------------------------------------------------------------------------
REM Error exits
REM ---------------------------------------------------------------------------
:bad_usage
echo [ERROR] Invalid arguments - both must be non-negative integers (watts / seconds).
echo Usage: nvidia_limit.bat [powerLimitWatts] [waitSeconds]
goto :fail

:fail
echo.
pause
endlocal & exit /b 1
