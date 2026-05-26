#!/usr/bin/env python3
"""
duality/template_setup.py — Cria/atualiza o template "RMM Agent Template"
com LLD (Low-Level Discovery) para drives e discos físicos.

Idempotente: re-execução não duplica itens/prototypes/triggers.
Estende fix.py: além dos itens estáticos antigos, adiciona regras de
descoberta + prototypes para que C:/D:/E:… e disco0/disco1/… apareçam
sozinhos no Zabbix conforme o agente os reporta.
"""
import sys
import os
from zabbix_utils import ZabbixAPI

SERVER_IP  = "techhousebc.ddns.net"
API_URL    = f"http://{SERVER_IP}:9090/zabbix/api_jsonrpc.php"
API_USER   = "Admin"
API_PASS   = os.environ.get("RMM_ZABBIX_PASS", "")
TEMPLATE   = "RMM Agent Template"
GROUP_ID   = "1"   # Templates


# ----------------------------------------------------------------------
# Itens estáticos (1 valor por host). Mesmos que server_template.py/fix.py.
# ----------------------------------------------------------------------
STATIC_ITEMS = [
    # Realtime
    {"name": "CPU Usage",         "key_": "cpu.usage",         "value_type": 0, "units": "%"},
    {"name": "Memory Usage",      "key_": "memory.usage",      "value_type": 0, "units": "%"},
    {"name": "Disk Usage",        "key_": "disk.usage",        "value_type": 0, "units": "%"},
    {"name": "CPU Temperature",   "key_": "cpu.temperature",   "value_type": 0, "units": "°C"},
    {"name": "GPU Temperature",   "key_": "gpu.temperature",   "value_type": 0, "units": "°C"},
    {"name": "System Uptime",     "key_": "sys.uptime_hours",  "value_type": 3, "units": "h"},
    # Specs numericos
    {"name": "CPU Cores",         "key_": "spec.cpu_cores",    "value_type": 3},
    {"name": "RAM Total",         "key_": "spec.ram_gb",       "value_type": 0, "units": "GB"},
    {"name": "Disk Size",         "key_": "spec.disk_size_gb", "value_type": 0, "units": "GB"},
    # Specs texto
    {"name": "CPU Model",         "key_": "spec.cpu_model",    "value_type": 4},
    {"name": "Disk Model",        "key_": "spec.disk_model",   "value_type": 4},
    {"name": "OS Version",        "key_": "spec.os_version",   "value_type": 4},
    {"name": "Machine Model",     "key_": "spec.machine_model","value_type": 4},
    {"name": "GPU Name",          "key_": "spec.gpu_name",     "value_type": 4},
    {"name": "Disk Interface",    "key_": "spec.disk_interface","value_type": 1},
    {"name": "RAM Type",          "key_": "spec.ram_type",     "value_type": 1},
    {"name": "Motherboard",       "key_": "spec.motherboard",  "value_type": 4},
    # Byte-based de boot disk (auto-escala em B/KB/MB/GB/TB no Zabbix)
    {"name": "Disk Reads",        "key_": "rmm.disk.reads",    "value_type": 3, "units": "B"},
    {"name": "Disk Writes",       "key_": "rmm.disk.writes",   "value_type": 3, "units": "B"},
    # rmm.* globais
    {"name": "OS Caption",        "key_": "rmm.os.caption",    "value_type": 4},
    {"name": "OS Architecture",   "key_": "rmm.os.arch",       "value_type": 1},
    {"name": "OS Uptime (Hours)", "key_": "rmm.os.uptime",     "value_type": 3, "units": "h"},
    {"name": "Hardware Model",    "key_": "rmm.hw.model",      "value_type": 1},
    {"name": "Hardware Serial",   "key_": "rmm.hw.serial",     "value_type": 1},
    {"name": "GPU Name (rmm)",    "key_": "rmm.gpu.name",      "value_type": 1},
    {"name": "GPU Utilization",   "key_": "rmm.gpu.util",      "value_type": 0, "units": "%"},
    {"name": "GPU Temperature",   "key_": "rmm.gpu.temp",      "value_type": 0, "units": "°C"},
    {"name": "GPU Memory Used",   "key_": "rmm.gpu.mem_used",  "value_type": 3, "units": "MB"},
]


# ----------------------------------------------------------------------
# LLD: descobertas e prototypes
# ----------------------------------------------------------------------
DISCOVERY_RULES = [
    {
        "name":   "Storage Drives",
        "key":    "rmm.storage.discovery",
        "prototypes": [
            {"name": "Storage Total ({#DRIVE}:)",
             "key_": "rmm.storage.total[{#DRIVE}:]",        "value_type": 3, "units": "B"},
            {"name": "Storage Free ({#DRIVE}:)",
             "key_": "rmm.storage.free[{#DRIVE}:]",         "value_type": 3, "units": "B"},
            {"name": "Storage Total GB ({#DRIVE}:)",
             "key_": "rmm.storage.total_gb[{#DRIVE}:]",     "value_type": 0, "units": "GB"},
            {"name": "Storage Free GB ({#DRIVE}:)",
             "key_": "rmm.storage.free_gb[{#DRIVE}:]",      "value_type": 0, "units": "GB"},
            {"name": "Storage Used % ({#DRIVE}:)",
             "key_": "rmm.storage.used_pct[{#DRIVE}:]",     "value_type": 0, "units": "%"},
        ],
        "triggers": [
            {"description": "Disco {#DRIVE}: quase cheio (>70%)",
             "expression":  "last(/{TEMPLATE}/rmm.storage.used_pct[{#DRIVE}:])>70",
             "priority": 2},
            {"description": "Disco {#DRIVE}: cheio (>80%)",
             "expression":  "last(/{TEMPLATE}/rmm.storage.used_pct[{#DRIVE}:])>80",
             "priority": 4},
            {"description": "Disco {#DRIVE}: crítico (>90%)",
             "expression":  "last(/{TEMPLATE}/rmm.storage.used_pct[{#DRIVE}:])>90",
             "priority": 5},
        ],
    },
    {
        "name":   "Physical Disks",
        "key":    "rmm.disk.discovery",
        "prototypes": [
            {"name": "Disk {#DISKID} Name ({#DISKNAME})",
             "key_": "rmm.disk.name[{#DISKID}]",            "value_type": 4},
            {"name": "Disk {#DISKID} Serial",
             "key_": "rmm.disk.serial[{#DISKID}]",          "value_type": 1},
            {"name": "Disk {#DISKID} Wear (%)",
             "key_": "rmm.disk.wear_pct[{#DISKID}]",        "value_type": 3, "units": "%"},
            {"name": "Disk {#DISKID} Health (%)",
             "key_": "rmm.disk.health_pct[{#DISKID}]",      "value_type": 3, "units": "%"},
            {"name": "Disk {#DISKID} Reads (GB)",
             "key_": "rmm.disk.reads_gb[{#DISKID}]",        "value_type": 0, "units": "GB"},
            {"name": "Disk {#DISKID} Writes (GB)",
             "key_": "rmm.disk.writes_gb[{#DISKID}]",       "value_type": 0, "units": "GB"},
            # Byte-based — Zabbix auto-escala B → KB → MB → GB → TB.
            {"name": "Disk {#DISKID} Reads",
             "key_": "rmm.disk.reads[{#DISKID}]",           "value_type": 3, "units": "B"},
            {"name": "Disk {#DISKID} Writes",
             "key_": "rmm.disk.writes[{#DISKID}]",          "value_type": 3, "units": "B"},
            {"name": "Disk {#DISKID} Temperature",
             "key_": "rmm.disk.temp[{#DISKID}]",            "value_type": 0, "units": "°C"},
            {"name": "Disk {#DISKID} SMART Status",
             "key_": "rmm.disk.smart_status[{#DISKID}]",    "value_type": 3},
            {"name": "Disk {#DISKID} Power-on Hours",
             "key_": "rmm.disk.poweron_hours[{#DISKID}]",   "value_type": 3, "units": "h"},
        ],
        "triggers": [
            {"description": "Disco {#DISKID} ({#DISKNAME}): SMART FAILED",
             "expression":  "last(/{TEMPLATE}/rmm.disk.smart_status[{#DISKID}])=1",
             "priority": 5},
            {"description": "Disco {#DISKID} ({#DISKNAME}): desgaste alto (>80%)",
             "expression":  "last(/{TEMPLATE}/rmm.disk.wear_pct[{#DISKID}])>80",
             "priority": 4},
            {"description": "Disco {#DISKID} ({#DISKNAME}): temperatura alta (>60°C)",
             "expression":  "last(/{TEMPLATE}/rmm.disk.temp[{#DISKID}])>60",
             "priority": 3},
            {"description": "Disco {#DISKID} ({#DISKNAME}): horas elevadas (>40000h)",
             "expression":  "last(/{TEMPLATE}/rmm.disk.poweron_hours[{#DISKID}])>40000",
             "priority": 2},
        ],
    },
]


# ----------------------------------------------------------------------
# Triggers globais (não-LLD)
# ----------------------------------------------------------------------
GLOBAL_TRIGGERS = [
    {"description": "RAM alta (>80% por 15 min)",
     "expression":  "avg(/{TEMPLATE}/memory.usage,15m)>80",      "priority": 4},
    {"description": "CPU temperatura alta (>55°C)",
     "expression":  "last(/{TEMPLATE}/cpu.temperature)>55",      "priority": 2},
    {"description": "CPU temperatura crítica (>65°C)",
     "expression":  "last(/{TEMPLATE}/cpu.temperature)>65",      "priority": 4},
    {"description": "Máquina reiniciada (uptime < 1h)",
     "expression":  "last(/{TEMPLATE}/sys.uptime_hours)<1",      "priority": 2},
]


# ----------------------------------------------------------------------
# Helpers idempotentes
# ----------------------------------------------------------------------
def upsert_item(api, template_id, item):
    try:
        api.item.create({
            "name": item["name"], "key_": item["key_"],
            "hostid": template_id, "type": 2,
            "value_type": item["value_type"],
            "units": item.get("units", ""),
            "delay": "0",
        })
        print(f"  [+] item   {item['key_']}")
    except Exception as e:
        if "already exists" in str(e).lower():
            print(f"  [-] item   {item['key_']} (já existe)")
        else:
            print(f"  [!] item   {item['key_']}: {e}")


def upsert_discovery_rule(api, template_id, name, key):
    existing = api.discoveryrule.get(
        filter={"key_": key}, hostids=template_id, output=["itemid"])
    if existing:
        print(f"  [-] LLD    {key} (já existe id={existing[0]['itemid']})")
        return existing[0]["itemid"]
    rule = api.discoveryrule.create({
        "name": name, "key_": key,
        "hostid": template_id, "type": 2,
        "delay": "0", "lifetime": "30d",
    })
    rid = rule["itemids"][0]
    print(f"  [+] LLD    {key} (id={rid})")
    return rid


def upsert_item_prototype(api, template_id, rule_id, proto):
    existing = api.itemprototype.get(
        filter={"key_": proto["key_"]}, hostids=template_id, output=["itemid"])
    if existing:
        print(f"    [-] proto  {proto['key_']} (já existe)")
        return
    try:
        payload = {
            "ruleid":  rule_id,
            "name":    proto["name"],
            "key_":    proto["key_"],
            "hostid":  template_id,
            "type":    2,
            "value_type": proto["value_type"],
            "units":   proto.get("units", ""),
            "delay":   "0",
        }
        api.itemprototype.create(payload)
        print(f"    [+] proto  {proto['key_']}")
    except Exception as e:
        print(f"    [!] proto  {proto['key_']}: {e}")


def upsert_trigger_prototype(api, template_id, trig):
    expr = trig["expression"].replace("{TEMPLATE}", TEMPLATE)
    desc = trig["description"]
    existing = api.triggerprototype.get(
        filter={"description": desc}, hostids=template_id, output=["triggerid"])
    if existing:
        print(f"    [-] trig   {desc} (já existe)")
        return
    try:
        api.triggerprototype.create({
            "description": desc, "expression": expr,
            "priority": trig["priority"], "status": 0,
        })
        print(f"    [+] trig   {desc}")
    except Exception as e:
        print(f"    [!] trig   {desc}: {e}")


def upsert_global_trigger(api, trig):
    expr = trig["expression"].replace("{TEMPLATE}", TEMPLATE)
    desc = trig["description"]
    existing = api.trigger.get(filter={"description": desc}, output=["triggerid"])
    if existing:
        print(f"  [-] trig   {desc} (já existe)")
        return
    try:
        api.trigger.create({
            "description": desc, "expression": expr,
            "priority": trig["priority"], "status": 0,
        })
        print(f"  [+] trig   {desc}")
    except Exception as e:
        print(f"  [!] trig   {desc}: {e}")


# ----------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------
def main():
    print(f"Conectando em {API_URL} …")
    api = ZabbixAPI(url=API_URL)
    try:
        api.login(user=API_USER, password=API_PASS)
    except Exception as e:
        print(f"Falha na conexão: {e}")
        sys.exit(1)

    existing = api.template.get(filter={"host": TEMPLATE})
    if existing:
        template_id = existing[0]["templateid"]
        print(f"Template '{TEMPLATE}' já existe (id={template_id}). Atualizando.")
    else:
        template_id = api.template.create({
            "host": TEMPLATE, "groups": [{"groupid": GROUP_ID}],
        })["templateids"][0]
        print(f"Template '{TEMPLATE}' criado (id={template_id}).")

    print("\n== Itens estáticos ==")
    for it in STATIC_ITEMS:
        upsert_item(api, template_id, it)

    print("\n== Regras LLD e prototypes ==")
    for rule in DISCOVERY_RULES:
        print(f"\n[{rule['name']}]")
        rid = upsert_discovery_rule(api, template_id, rule["name"], rule["key"])
        for proto in rule["prototypes"]:
            upsert_item_prototype(api, template_id, rid, proto)
        for trig in rule["triggers"]:
            upsert_trigger_prototype(api, template_id, trig)

    print("\n== Triggers globais ==")
    for trig in GLOBAL_TRIGGERS:
        upsert_global_trigger(api, trig)

    print("\nTemplate sincronizado.")


if __name__ == "__main__":
    main()
