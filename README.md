# zbxagent

Agente RMM em Nim para Zabbix Server. Coleta CPU/RAM/GPU/temperatura,
SMART por disco (com LLD), LibreHardwareMonitor para temp de CPU em
Ryzen/Intel, CrystalDiskInfo para drives atrás de Intel VMD/RST.
Suporta auto-update via GitHub Releases.

## Layout do repositório

```
src/                   código Nim do agente
  agent.nim              ponto de entrada
  collectors.nim         coletores cross-platform (CPU/RAM/GPU/SMART)
  collectors_lld.nim     LLD + per-disk wear/reads/writes/health
  cdi_client.nim         spawn + parse de CrystalDiskInfo
  lhm_client.nim         HTTP client para LibreHardwareMonitor
  updater.nim            auto-update via GitHub Releases
  config.nim             carrega agent.conf
scripts/               scripts de servidor + build
  template_setup.py      cria template no Zabbix (LLD + triggers)
  cleanup_legacy_items.py / reenable_legacy_items.py   utilitários
  release.ps1            build + upload de nova release
installer/             scripts de instalação por host
  install-local.bat      para hosts na LAN
  install-remote.bat     para hosts remotos (via DDNS)
  register_host.ps1      auto-registra host no Zabbix via API
  fetch_lhm.ps1          baixa LibreHardwareMonitor on-demand
  LibreHardwareMonitor.config   config pré-configurada do LHM
```

## Variáveis de ambiente

Os scripts não trazem credenciais hardcoded. Defina antes de executar:

```powershell
$env:RMM_ZABBIX_PASS = "..."     # senha do Admin do Zabbix
```

Ou os scripts perguntam interativamente.

## Setup inicial do template

Uma vez por servidor Zabbix:

```powershell
$env:RMM_ZABBIX_PASS = "..."
python scripts\template_setup.py
```

Idempotente — re-executar é seguro, só cria o que faltar.

## Instalação por host (primeira vez)

Apenas a primeira vez precisa do bundle completo (binários de terceiros
não vêm no repo). Baixe a release `installer-remote.zip` (ou `local`)
da página de Releases, extraia, execute como Admin:

```powershell
$env:RMM_ZABBIX_PASS = "..."
.\install-remote.bat
```

## Auto-update

A partir da v1.0.0, hosts checam `releases/latest/download/version.txt`
a cada hora. Se a versão remota for maior:

1. Agente baixa `agent.exe` para `agent.exe.new`
2. Verifica SHA256 contra a linha 2 do `version.txt`
3. Sai. NSSM reinicia o serviço.
4. O hook `Start/Pre` do NSSM (registrado pelo install) renomeia
   `agent.exe.new` → `agent.exe` antes de subir o agente.

## Publicar nova versão

```powershell
.\scripts\release.ps1 -Version 1.0.1            # build local + version.txt
.\scripts\release.ps1 -Version 1.0.1 -Upload    # também publica no GitHub
```

`-Upload` requer `gh auth login` configurado uma vez.

## Build manual

```powershell
cd src
nim c -d:release --opt:speed agent.nim
```

Requer Nim 2.x.
