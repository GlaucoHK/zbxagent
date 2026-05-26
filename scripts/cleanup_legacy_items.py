#!/usr/bin/env python3
"""
cleanup_legacy_items.py — Desabilita itens legados não-indexados do
template "RMM Agent Template" que ficaram órfãos após migração para
LLD. O novo agente (duality/sojourn) envia apenas chaves indexadas
(rmm.disk.reads_gb[0], rmm.storage.used_pct[C:], etc.), então os
itens antigos sem [N]/[C:] não recebem mais dados.

Desabilita (status=1) em vez de deletar para não quebrar actions/triggers
que ainda referenciam esses itens. Itens desabilitados somem do
"Latest data" e não disparam alertas com dados stale, mas as triggers
permanecem definidas (dormentes) para auditoria.

Itens desabilitados:
  - hdd.*                  (substituídos por rmm.disk.*[N])
  - rmm.disk.* sem [N]     (idem)
  - rmm.storage.* sem [X:] (substituídos pelos prototypes de LLD)

Idempotente: rode quantas vezes quiser.
"""
import sys
import os
from zabbix_utils import ZabbixAPI

API_URL  = "http://techhousebc.ddns.net:9090/zabbix/api_jsonrpc.php"
API_USER = "Admin"
API_PASS = os.environ.get("RMM_ZABBIX_PASS", "")
TEMPLATE = "RMM Agent Template"

# Chaves a remover (exatamente como estão no template)
LEGACY_KEYS = [
    "hdd.poweron_hours",
    "hdd.smart_status",
    "rmm.disk.health",
    "rmm.disk.health_pct",
    "rmm.disk.temp",
    "rmm.disk.reads_gb",
    "rmm.disk.writes_gb",
    "rmm.disk.wear_pct",
    "rmm.storage.total[C:]",
    "rmm.storage.free[C:]",
    "rmm.storage.used_pct[C:]",
    "rmm.storage.total_gb[C:]",
    "rmm.storage.free_gb[C:]",
    "rmm.storage.total[D:]",
    "rmm.storage.free[D:]",
    "rmm.storage.total_gb[D:]",
    "rmm.storage.free_gb[D:]",
    "rmm.storage.used_pct[D:]",
]


def main():
    api = ZabbixAPI(url=API_URL)
    api.login(user=API_USER, password=API_PASS)

    t = api.template.get(filter={"host": TEMPLATE}, output=["templateid"])
    if not t:
        print(f"Template '{TEMPLATE}' não encontrado.")
        sys.exit(1)
    tid = t[0]["templateid"]
    print(f"Template '{TEMPLATE}' (id={tid})")

    disabled = 0
    already  = 0
    missing  = 0
    for key in LEGACY_KEYS:
        items = api.item.get(filter={"key_": key}, hostids=tid,
                             output=["itemid", "key_", "status"])
        if not items:
            print(f"  [-] {key} (não existe)")
            missing += 1
            continue
        for it in items:
            if str(it.get("status", "0")) == "1":
                print(f"  [-] {key} (já desabilitado)")
                already += 1
                continue
            api.item.update({"itemid": it["itemid"], "status": "1"})
            print(f"  [x] {key} (desabilitado id={it['itemid']})")
            disabled += 1

    print(f"\nFeito. {disabled} desabilitados, {already} já estavam, "
          f"{missing} ausentes.")


if __name__ == "__main__":
    main()
