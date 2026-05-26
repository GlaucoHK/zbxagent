#!/usr/bin/env python3
"""
reenable_legacy_items.py — Undoes cleanup_legacy_items.py.
Reabilita itens estáticos que tinham sido desabilitados, restaurando
o caminho legado de envio (chaves não-indexadas para o disco/drive
de boot). O novo agente agora também envia para essas chaves para
manter compatibilidade com triggers existentes.
"""
import sys
import os
from zabbix_utils import ZabbixAPI

API_URL  = "http://techhousebc.ddns.net:9090/zabbix/api_jsonrpc.php"
API_USER = "Admin"
API_PASS = os.environ.get("RMM_ZABBIX_PASS", "")
TEMPLATE = "RMM Agent Template"

LEGACY_KEYS = [
    "hdd.poweron_hours", "hdd.smart_status",
    "rmm.disk.health", "rmm.disk.health_pct", "rmm.disk.temp",
    "rmm.disk.reads_gb", "rmm.disk.writes_gb", "rmm.disk.wear_pct",
    "rmm.storage.total[C:]", "rmm.storage.free[C:]",
    "rmm.storage.used_pct[C:]", "rmm.storage.total_gb[C:]",
    "rmm.storage.free_gb[C:]",
    "rmm.storage.total[D:]", "rmm.storage.free[D:]",
    "rmm.storage.total_gb[D:]", "rmm.storage.free_gb[D:]",
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

    enabled = already = missing = 0
    for key in LEGACY_KEYS:
        items = api.item.get(filter={"key_": key}, hostids=tid,
                             output=["itemid", "key_", "status"])
        if not items:
            print(f"  [-] {key} (não existe)")
            missing += 1
            continue
        for it in items:
            if str(it.get("status", "0")) == "0":
                print(f"  [-] {key} (já habilitado)")
                already += 1
                continue
            api.item.update({"itemid": it["itemid"], "status": "0"})
            print(f"  [x] {key} (reabilitado id={it['itemid']})")
            enabled += 1

    print(f"\nFeito. {enabled} reabilitados, {already} já estavam, "
          f"{missing} ausentes.")


if __name__ == "__main__":
    main()
