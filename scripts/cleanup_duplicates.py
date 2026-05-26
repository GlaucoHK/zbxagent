#!/usr/bin/env python3
"""
cleanup_duplicates.py — Desabilita itens duplicados no template
"RMM Agent Template". QA pediu: "leaving only one of each, leaving
them to only appear if there's a D, E etc. drive".

Estratégia: tudo passa pelo LLD (rmm.disk.discovery). Items
não-indexados e prototypes _gb redundantes ficam desabilitados.

DISABLED (não deletados; preservam histórico + definições de trigger):
  - Unindexed legacy (boot disk values duplicados com [0]):
      rmm.disk.reads, rmm.disk.reads_gb,
      rmm.disk.writes, rmm.disk.writes_gb,
      rmm.disk.health, rmm.disk.health_pct,
      rmm.disk.wear_pct, rmm.disk.temp,
      hdd.poweron_hours, hdd.smart_status

  - LLD prototypes _gb (duplicam rmm.disk.reads[{#DISKID}] em bytes,
    que já auto-escala TB/GB/MB no Zabbix com units=B):
      rmm.disk.reads_gb[{#DISKID}], rmm.disk.writes_gb[{#DISKID}]

MANTIDOS:
  - spec.disk_model (QA preferiu manter — "what's on the boot disk?")
  - Todos os prototypes via LLD (1 conjunto por disco descoberto)

Idempotente.
"""
import sys, os
from zabbix_utils import ZabbixAPI

API_URL  = "http://techhousebc.ddns.net:9090/zabbix/api_jsonrpc.php"
API_USER = "Admin"
API_PASS = os.environ.get("RMM_ZABBIX_PASS", "")
TEMPLATE = "RMM Agent Template"

UNINDEXED_KEYS_TO_DISABLE = [
    "rmm.disk.reads",
    "rmm.disk.reads_gb",
    "rmm.disk.writes",
    "rmm.disk.writes_gb",
    "rmm.disk.health",
    "rmm.disk.health_pct",
    "rmm.disk.wear_pct",
    "rmm.disk.temp",
    "hdd.poweron_hours",
    "hdd.smart_status",
]

PROTOTYPE_KEYS_TO_DISABLE = [
    "rmm.disk.reads_gb[{#DISKID}]",
    "rmm.disk.writes_gb[{#DISKID}]",
]


def disable_items(api, tid, keys, label, kind):
    """kind = 'item' ou 'itemprototype'."""
    print(f"\n== {label} ==")
    disabled = already = missing = 0
    api_obj = getattr(api, kind)
    for key in keys:
        items = api_obj.get(filter={"key_": key}, hostids=tid,
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
            update_id_key = "itemid"
            payload = {update_id_key: it["itemid"], "status": "1"}
            api_obj.update(payload)
            print(f"  [x] {key} (desabilitado id={it['itemid']})")
            disabled += 1
    print(f"  -> {disabled} desabilitados, {already} já estavam, "
          f"{missing} ausentes.")


def main():
    if not API_PASS:
        print("Defina RMM_ZABBIX_PASS no environment.")
        sys.exit(1)
    api = ZabbixAPI(url=API_URL)
    api.login(user=API_USER, password=API_PASS)
    t = api.template.get(filter={"host": TEMPLATE}, output=["templateid"])
    if not t:
        print(f"Template '{TEMPLATE}' não encontrado.")
        sys.exit(1)
    tid = t[0]["templateid"]
    print(f"Template '{TEMPLATE}' (id={tid})")

    disable_items(api, tid, UNINDEXED_KEYS_TO_DISABLE,
                  "Items não-indexados legados", "item")
    disable_items(api, tid, PROTOTYPE_KEYS_TO_DISABLE,
                  "Prototypes _gb redundantes (rmm.disk.reads[N] já auto-escala)",
                  "itemprototype")
    print("\nCleanup concluído.")


if __name__ == "__main__":
    main()
