@echo off
setlocal EnableExtensions
title AppDynamics Config Exporter
cd /d "%~dp0"

rem ---------------------------------------------------------------------------
rem  Settings - edit only if needed
rem ---------------------------------------------------------------------------
rem  Port for the local web UI (http://localhost:PORT)
set "CE_PORT=8282"

rem  Corporate proxy, if the laptop needs one to reach *.saas.appdynamics.com.
rem  Leave empty for a direct connection. Example: CE_PROXY_HOST=proxy.pobal.ie
set "CE_PROXY_HOST="
set "CE_PROXY_PORT=8080"

rem  Java heap. Raise to 2g for very large applications.
set "CE_HEAP=1g"
rem ---------------------------------------------------------------------------

set "WAR="
for %%F in (config-exporter*.war) do set "WAR=%%F"
if not defined WAR (
    echo [ERROR] No config-exporter*.war file found in "%~dp0".
    echo         Put the .war file in the same folder as this script.
    pause
    exit /b 1
)

where java >nul 2>&1
if errorlevel 1 (
    echo [ERROR] Java was not found on PATH.
    echo         Install a Java 17 or 21 runtime ^(for example Eclipse Temurin 21 JRE^),
    echo         tick "Add to PATH" during install, then run this script again.
    pause
    exit /b 1
)

set "JAVA_VER="
for /f "tokens=3" %%V in ('java -version 2^>^&1 ^| findstr /i "version"') do set "JAVA_VER=%%~V"
set "JAVA_MAJOR="
for /f "delims=.-+" %%M in ("%JAVA_VER%") do set "JAVA_MAJOR=%%M"
if not defined JAVA_MAJOR set "JAVA_MAJOR=0"
if %JAVA_MAJOR% LSS 17 (
    echo [ERROR] Java %JAVA_VER% found, but Config Exporter needs Java 17 or newer.
    echo         Install Eclipse Temurin 21 JRE, tick "Add to PATH", then run this script again.
    pause
    exit /b 1
)

netstat -ano | findstr /R /C:":%CE_PORT% .*LISTENING" >nul 2>&1
if not errorlevel 1 (
    echo [ERROR] Port %CE_PORT% is already in use. Is Config Exporter already running?
    echo         Close the other window, or change CE_PORT at the top of this script.
    pause
    exit /b 1
)

set "PROXY_OPTS="
if defined CE_PROXY_HOST set "PROXY_OPTS=-Dhttps.proxyHost=%CE_PROXY_HOST% -Dhttps.proxyPort=%CE_PROXY_PORT%"

echo Starting %WAR% ...
echo When you see "Started ConfigExporterApplication", open http://localhost:%CE_PORT%
echo Keep this window open while you use the tool. Close it to stop Config Exporter.
echo.

start "" /b cmd /c "timeout /t 25 /nobreak >nul && start http://localhost:%CE_PORT%"

rem  server.address=127.0.0.1 : the UI has no login of its own, so it must not be
rem                             reachable from other machines on the network.
rem  persist.controller.details=false : do not save controller passwords to disk.
java -Xms512m -Xmx%CE_HEAP% ^
     -Dserver.address=127.0.0.1 ^
     -Dserver.port=%CE_PORT% ^
     -Duser.authentication.enabled=false ^
     -Dpersist.controller.details=false ^
     %PROXY_OPTS% ^
     -jar "%WAR%"

echo.
echo Config Exporter has stopped.
pause
