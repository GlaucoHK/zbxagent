# Package: rmm_agent
version       = "0.1.0"
author        = "Davi Dias Kechner"
description   = "Agente RMM para coleta de métricas e envio ao Zabbix"
license       = "MIT"

requires "nim >= 1.6.0"

when defined(windows):
  requires "winim >= 3.9.0"

task build, "Compila para a plataforma atual (otimizado)":
  exec "nim c -d:release --opt:size --app:console agent.nim"

task build_windows, "Compila para Windows 64 bits":
  exec "nim c -d:release --opt:size --cpu:amd64 --os:windows agent.nim"

task build_linux, "Compila para Linux 64 bits":
  exec "nim c -d:release --opt:size --cpu:amd64 --os:linux agent.nim"

task build_macos, "Compila para macOS 64 bits (requer toolchain)":
  exec "nim c -d:release --opt:size --cpu:amd64 --os:macosx agent.nim"

task build_all, "Compila para Windows e Linux":
  exec "nim c -d:release --opt:size --cpu:amd64 --os:windows agent.nim"
  exec "nim c -d:release --opt:size --cpu:amd64 --os:linux agent.nim"
  # Descomente a linha abaixo se tiver toolchain para macOS
  # exec "nim c -d:release --opt:size --cpu:amd64 --os:macosx agent.nim"

task run, "Compila e executa o agente":
  exec "nim c -r agent.nim"

task install_deps, "Instala as dependências necessárias":
  when defined(windows):
    exec "nimble install winim"
  else:
    echo "Nenhuma dependência extra necessária para este SO."