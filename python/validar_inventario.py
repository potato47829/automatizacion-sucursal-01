#!/usr/bin/env python3
"""Prototipo 4: relaciona YAML, JSON (IPAM simulado) y evidencias de Ansible.

Fuentes: variables/*.yml, inventario/hosts.yml, datos/ipam_sucursal_01.json y
respaldos/<equipo>/ (running-config, vlan-brief). No usa red ni SSH.
Separa el resultado en coincidencias, faltantes y diferencias.
"""
import argparse
import ipaddress
import json
import sys
from pathlib import Path

from comun import (RAIZ, cargar_yaml, hostname, inventario, leer,
                   parsear_interfaces, parsear_vlans, valor)

FUNCION_POR_GRUPO = {"routers": "router", "switches": "switch"}


def comparar(elemento, fuentes, resultado):
    """fuentes = {nombre_fuente: valor o None}. Clasifica el elemento."""
    presentes = {k: v for k, v in fuentes.items() if v is not None}
    ausentes = [k for k, v in fuentes.items() if v is None]
    detalle = ", ".join(f"{k}={v}" for k, v in presentes.items())
    if len(set(presentes.values())) > 1:
        resultado["diferencias"].append(f"{elemento}: {detalle}")
    if ausentes:
        resultado["faltantes"].append(f"{elemento}: no aparece en {', '.join(ausentes)} ({detalle})")
    if not ausentes and len(set(presentes.values())) == 1:
        resultado["coincidencias"].append(f"{elemento}: {detalle}")


def ip_de(lineas):
    texto = valor(lineas or [], "ip address ")
    return texto.split()[0] if texto else None


def red_de(lineas):
    texto = valor(lineas or [], "ip address ")
    if not texto:
        return None
    ip, mascara = texto.split()
    return str(ipaddress.ip_interface(f"{ip}/{mascara}").network)


def main():
    ap = argparse.ArgumentParser(description="Compara YAML, IPAM (JSON) y evidencias de los equipos.")
    ap.add_argument("--ipam", type=Path, default=RAIZ / "datos" / "ipam_sucursal_01.json")
    ap.add_argument("--respaldos", type=Path, default=RAIZ / "respaldos")
    args = ap.parse_args()

    ipam = json.loads(args.ipam.read_text(encoding="utf-8"))
    vlans_yaml = {v["id"]: v for v in cargar_yaml(RAIZ / "variables" / "vlans.yml")["vlans"]}
    prefijos = {p["vlan"]: p for p in ipam["prefijos"]}
    dispositivos = {d["nombre"]: d for d in ipam["dispositivos"]}
    equipos = inventario()
    print(f"Datos leidos: {args.ipam} ({len(prefijos)} prefijos, {len(dispositivos)} dispositivos), "
          f"variables/*.yml, inventario/hosts.yml y {args.respaldos}/<equipo>/")

    r = {"coincidencias": [], "faltantes": [], "diferencias": []}
    router = next(e for e, d in equipos.items() if d["grupo"] == "routers")
    config_router = leer(args.respaldos / router / "running-config.txt")
    if_router = parsear_interfaces(config_router) if config_router else {}
    troncal = cargar_yaml(RAIZ / "variables" / f"{router}.yml")["trunk_interface"]["name"]
    primer_switch = next(e for e, d in equipos.items() if d["grupo"] == "switches")
    brief = leer(args.respaldos / primer_switch / "vlan-brief.txt")
    vlans_switch = parsear_vlans(brief) if brief else {}

    # 1. VLAN, red y gateway: IPAM vs YAML vs configuracion del router
    for vid in sorted(set(vlans_yaml) | set(prefijos)):
        y, p = vlans_yaml.get(vid), prefijos.get(vid)
        sub = if_router.get(f"{troncal}.{vid}")
        comparar(f"VLAN {vid} nombre", {
            "IPAM": p and p["nombre"], "YAML": y and y["name"],
            f"{primer_switch} (vlan-brief)": (vlans_switch.get(vid) or {}).get("nombre")}, r)
        comparar(f"VLAN {vid} red", {
            "IPAM": p and p["red"], "YAML": y and y["network"], f"{router} (running-config)": red_de(sub)}, r)
        comparar(f"VLAN {vid} gateway", {
            "IPAM": p and p["gateway"], "YAML": y and y["gateway"], f"{router} (running-config)": ip_de(sub)}, r)

    # 2 y 3. Direccion de gestion, nombre y funcion de cada equipo
    for equipo in sorted(set(equipos) | set(dispositivos)):
        inv, d = equipos.get(equipo), dispositivos.get(equipo)
        diseno = cargar_yaml(RAIZ / "variables" / f"{equipo}.yml") if inv else {}
        config = leer(args.respaldos / equipo / "running-config.txt") if inv else None
        interfaces = parsear_interfaces(config) if config else {}
        if "management" in diseno:
            doc, bloque = diseno["management"]["ip"], interfaces.get(f"Vlan{diseno['management']['vlan']}")
        else:
            enlace = diseno.get("automation_link", {})
            doc, bloque = enlace.get("ip"), interfaces.get(enlace.get("interface"))
        comparar(f"{equipo} direccion de gestion", {
            "IPAM": d and d["direccion_gestion"], "YAML": doc,
            "inventario (ansible_host)": inv and inv["ip"], "running-config": ip_de(bloque)}, r)
        comparar(f"{equipo} nombre", {
            "IPAM": d and d["nombre"], "inventario": equipo if inv else None,
            "running-config": hostname(config) if config else None}, r)
        comparar(f"{equipo} funcion", {
            "IPAM": d and d["funcion"], "inventario (grupo)": inv and FUNCION_POR_GRUPO[inv["grupo"]]}, r)

    for titulo in ("coincidencias", "faltantes", "diferencias"):
        print(f"\n== {titulo.upper()} ({len(r[titulo])}) ==")
        for linea in r[titulo]:
            print(f"  [{titulo[:-1].upper() if titulo != 'faltantes' else 'FALTANTE'}] {linea}")
    print(f"\nResumen: {len(r['coincidencias'])} coincidencias, {len(r['faltantes'])} faltantes, "
          f"{len(r['diferencias'])} diferencias.")
    return 1 if r["faltantes"] or r["diferencias"] else 0


if __name__ == "__main__":
    sys.exit(main())
