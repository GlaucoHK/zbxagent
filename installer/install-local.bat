@echo off
setlocal enabledelayedexpansion

:: sojourn/install_service.bat — Instala RMM-Agent + LibreHardwareMonitor
:: como dois serviços separados (RMM-LHM antes do RMM-Agent).
::
:: Bundle inclui:
::   - fetch_lhm.ps1            (baixa LHM se não estiver presente)
::   - LibreHardwareMonitor.config (pré-configurado, HTTP em 8085)
::
:: AVISO DE SEGURANÇA:
::   LHM carrega o driver WinRing0x64.sys (versão re-assinada pelo
::   projeto LHM, 2023+). Em hosts com HVCI/Memory Integrity ou Smart
::   App Control ligados o driver é bloqueado e o agente cai no
::   fallback WMI automaticamente — a temperatura da CPU fica em 0
::   nesses hosts. Considere o aumento da superfície de ataque (ring 0
::   via MSR) antes de implantar em larga escala.

net session >nul 2>&1
if %errorlevel% neq 0 (
    echo ERRO: Execute como Administrador.
    pause
    exit /b 1
)

set "SCRIPT_DIR=%~dp0"
set "TARGET_DIR=%PROGRAMFILES%\RMM-Agent"
set "LHM_DIR=%PROGRAMFILES%\RMM-LHM"
:: LOCAL = instalador para uso interno (LAN). Conexao direta ao IP da VM
:: Zabbix sem passar pelo DDNS/NAT do roteador. Para maquinas fora da
:: rede local, use sojourn-deploy/ (aponta para techhousebc.ddns.net).
set "ZABBIX_SERVER=192.168.15.55"
set "INTERVAL=60"
set "API_URL=http://%ZABBIX_SERVER%:9090/zabbix/api_jsonrpc.php"
set "API_USER=Admin"

:: Password vem da variável de ambiente para não ficar hardcoded.
:: Se nao definida, pergunta interativamente.
if "%RMM_ZABBIX_PASS%"=="" (
    set /p "API_PASS=Senha Zabbix Admin: "
) else (
    set "API_PASS=%RMM_ZABBIX_PASS%"
)
if "%API_PASS%"=="" (
    echo ERRO: senha vazia.
    pause
    exit /b 1
)

:: Arquivos obrigatórios do agente
for %%f in (agent.exe zabbix_sender.exe nssm.exe smartctl.exe register_host.ps1 fetch_lhm.ps1 LibreHardwareMonitor.config) do (
    if not exist "%SCRIPT_DIR%%%f" (
        echo ERRO: %%f nao encontrado em %SCRIPT_DIR%
        pause
        exit /b 1
    )
)

set "HOSTNAME=%COMPUTERNAME%"
echo Hostname:  %HOSTNAME%
echo Zabbix:    %ZABBIX_SERVER%
echo Intervalo: %INTERVAL%s

:: -------------- Garante LHM presente ----------------
if not exist "%LHM_DIR%" mkdir "%LHM_DIR%"

if not exist "%LHM_DIR%\LibreHardwareMonitor.exe" (
    if exist "%SCRIPT_DIR%LibreHardwareMonitor.exe" (
        echo Copiando LHM de %SCRIPT_DIR% para %LHM_DIR%...
        xcopy /Y /E "%SCRIPT_DIR%LibreHardwareMonitor*" "%LHM_DIR%\" >nul
        if exist "%SCRIPT_DIR%HidSharp.dll" copy /Y "%SCRIPT_DIR%HidSharp.dll" "%LHM_DIR%\" >nul
    ) else (
        echo LHM nao encontrado localmente. Baixando do GitHub...
        powershell -ExecutionPolicy Bypass -File "%SCRIPT_DIR%fetch_lhm.ps1" -DestDir "%LHM_DIR%"
        if errorlevel 1 (
            echo AVISO: Falha ao baixar LHM. Agente prosseguira com fallback WMI.
            set "LHM_OK=0"
            goto LhmDone
        )
    )
)

:: Copia config pré-configurado (HTTP em 8085)
copy /Y "%SCRIPT_DIR%LibreHardwareMonitor.config" "%LHM_DIR%\LibreHardwareMonitor.config" >nul

set "LHM_OK=1"

sc query RMM-LHM >nul 2>&1 && (
    net stop RMM-LHM >nul 2>&1
    sc delete RMM-LHM >nul 2>&1
    timeout /t 2 >nul
)

"%SCRIPT_DIR%nssm.exe" install RMM-LHM "%LHM_DIR%\LibreHardwareMonitor.exe"
"%SCRIPT_DIR%nssm.exe" set RMM-LHM Start SERVICE_AUTO_START
"%SCRIPT_DIR%nssm.exe" set RMM-LHM AppDirectory "%LHM_DIR%"
"%SCRIPT_DIR%nssm.exe" set RMM-LHM AppStdout "%LHM_DIR%\lhm.log"
"%SCRIPT_DIR%nssm.exe" set RMM-LHM AppStderr "%LHM_DIR%\lhm.log"
"%SCRIPT_DIR%nssm.exe" set RMM-LHM ObjectName LocalSystem

net start RMM-LHM
if errorlevel 1 (
    echo AVISO: RMM-LHM nao iniciou ^(driver bloqueado por HVCI/SAC?^).
    echo        Agente usara fallback WMI para CPU temp.
    set "LHM_OK=0"
)
timeout /t 3 >nul

:LhmDone

:: -------------- Instala agente -------------
if not exist "%TARGET_DIR%" mkdir "%TARGET_DIR%"
copy /Y "%SCRIPT_DIR%agent.exe"         "%TARGET_DIR%\" >nul
copy /Y "%SCRIPT_DIR%zabbix_sender.exe" "%TARGET_DIR%\" >nul
copy /Y "%SCRIPT_DIR%nssm.exe"          "%TARGET_DIR%\" >nul
copy /Y "%SCRIPT_DIR%smartctl.exe"      "%TARGET_DIR%\" >nul
copy /Y "%SCRIPT_DIR%register_host.ps1" "%TARGET_DIR%\" >nul

:: CrystalDiskInfo bundle (fallback final para drives atrás de Intel VMD/RST)
if exist "%SCRIPT_DIR%CDI\DiskInfo64.exe" (
    if not exist "%TARGET_DIR%\CDI" mkdir "%TARGET_DIR%\CDI"
    xcopy /Y /E /Q "%SCRIPT_DIR%CDI" "%TARGET_DIR%\CDI\" >nul
    echo CDI instalado em %TARGET_DIR%\CDI
)

echo Server=%ZABBIX_SERVER%>"%TARGET_DIR%\agent.conf"
echo Port=10051>>"%TARGET_DIR%\agent.conf"
echo Hostname=%HOSTNAME%>>"%TARGET_DIR%\agent.conf"
echo Interval=%INTERVAL%>>"%TARGET_DIR%\agent.conf"

echo Registrando host no Zabbix...
powershell -ExecutionPolicy Bypass -File "%TARGET_DIR%\register_host.ps1" -apiUrl "%API_URL%" -user "%API_USER%" -pass "%API_PASS%" -hostname "%HOSTNAME%"
if errorlevel 1 (
    echo AVISO: Falha no registro via API. Pressione qualquer tecla para continuar...
    pause
)

sc query RMM-Agent >nul 2>&1 && (
    net stop RMM-Agent >nul 2>&1
    sc delete RMM-Agent >nul 2>&1
    timeout /t 2 >nul
)

"%TARGET_DIR%\nssm.exe" install RMM-Agent "%TARGET_DIR%\agent.exe"
"%TARGET_DIR%\nssm.exe" set RMM-Agent Start SERVICE_AUTO_START
"%TARGET_DIR%\nssm.exe" set RMM-Agent AppDirectory "%TARGET_DIR%"
"%TARGET_DIR%\nssm.exe" set RMM-Agent AppStdout "%TARGET_DIR%\agent.log"
"%TARGET_DIR%\nssm.exe" set RMM-Agent AppStderr "%TARGET_DIR%\agent.log"
if "%LHM_OK%"=="1" (
    "%TARGET_DIR%\nssm.exe" set RMM-Agent DependOnService RMM-LHM
)

:: Nota: o swap do binário no auto-update é feito pelo próprio agente
:: spawnando _zbxagent_swap.bat (ver updater.nim). NSSM não suporta
:: pre-start hooks; tentativa anterior com AppEvents foi removida.

net start RMM-Agent

echo ========================================
echo Sojourn instalado.
echo Host:    %HOSTNAME%
echo Zabbix:  %ZABBIX_SERVER%:10051
echo LHM ok:  %LHM_OK% ^(HTTP localhost:8085^)
echo Logs:    %TARGET_DIR%\agent.log
echo ========================================
pause
