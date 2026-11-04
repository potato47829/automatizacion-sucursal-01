#!/usr/bin/env python3
"""Prototipo 3: auditoria de una flota pequena (router y dos switches).

Amplia auditoria/auditar.py. Lee el diseno (variables/*.yml) y la evidencia que
dejo Ansible en respaldos/<equipo>/. Genera una tabla en pantalla y un CSV.
No se conecta a ningun equipo.
"""
import argparse
import csv
import re
import sys
from pathlib import Path

from comun import (RAIZ, cargar_yaml, corta, hostname, inventario, leer,
                   parsear_interfaces, parsear_ip_brief, parsear_trunk, valor)
import auditar  # noqa: E402  (auditoria/auditar.py; comun.py ya agrego su carpeta al path)


def version_ios(texto):
    m = re.search(r"Version\s+([^\s,]+)", texto)
    return m.group(1) if m else None


class Auditoria:
    def __init__(self, equipo, carpeta):
        self.equipo, self.carpeta, self.filas = equipo, carpeta, []

    def agregar(self, condicion, problemas, evidencia):
        self.filas.append({"equipo": self.equipo, "condicion": condicion,
                           "resultado": "CUMPLE" if not problemas else "NO CUMPLE",
                           "evidencia": evidencia, "detalle": "; ".join(problemas)})

    def texto(self, archivo):
        """Lee una evidencia; si falta, registra un NO CUMPLE y devuelve None."""
        contenido = leer(self.carpeta / archivo)
        if contenido is None:
            self.agregar(f"Evidencia {archivo} disponible", [f"no existe {self.carpeta / archivo}"], archivo)
        return contenido


def auditar_switch(equipo, diseno, vlans, carpeta, versiones):
    a = Auditoria(equipo, carpeta)
    config = a.texto("running-config.txt")
    brief = a.texto("vlan-brief.txt")
    trunk = a.texto("interfaces-trunk.txt")
    ipb = a.texto("ip-interface-brief.txt")
    ver = a.texto("version.txt")

    if config:
        interfaces = parsear_interfaces(config)
        a.agregar("Hostname coincide con el diseno",
                  [] if hostname(config) == diseno["hostname"] else [f"esperado {diseno['hostname']}, encontrado {hostname(config)}"],
                  "running-config.txt")
        ruta = f"ip route 0.0.0.0 0.0.0.0 {diseno['management']['gateway']}"
        a.agregar("Ruta por defecto hacia el gateway de gestion",
                  [] if ruta in config.splitlines() else [f"falta la linea '{ruta}'"], "running-config.txt")
        for elemento, problemas in auditar.auditar_troncales(diseno["trunks"], interfaces):
            a.agregar(elemento + " (configuracion)", problemas, "running-config.txt")
        for elemento, problemas in auditar.auditar_acceso(diseno["access_ports"], interfaces):
            a.agregar(elemento, problemas, "running-config.txt")
    if brief:
        for elemento, problemas in auditar.auditar_vlans(vlans, auditar.parsear_vlans(brief)):
            a.agregar(elemento, problemas, "vlan-brief.txt")
    if trunk:
        info = parsear_trunk(trunk)
        for t in diseno["trunks"]:
            real, problemas = info.get(corta(t["interface"])), []
            if real is None:
                problemas.append("el puerto no aparece en show interfaces trunk")
            else:
                if real.get("estado") != "trunking":
                    problemas.append(f"estado esperado trunking, encontrado {real.get('estado')}")
                if real.get("nativa") != str(t["native_vlan"]):
                    problemas.append(f"nativa esperada {t['native_vlan']}, encontrada {real.get('nativa')}")
                esperadas = ",".join(str(v) for v in t["allowed_vlans"])
                if real.get("permitidas") != esperadas:
                    problemas.append(f"permitidas esperadas {esperadas}, encontradas {real.get('permitidas')}")
            a.agregar(f"{t['interface']} troncal (estado operativo)", problemas, "interfaces-trunk.txt")
    if ipb:
        m = diseno["management"]
        real, problemas = parsear_ip_brief(ipb).get(f"Vlan{m['vlan']}"), []
        if real is None:
            problemas.append("la SVI de gestion no aparece")
        else:
            if real["ip"] != m["ip"]:
                problemas.append(f"IP esperada {m['ip']}, encontrada {real['ip']}")
            if (real["estado"], real["protocolo"]) != ("up", "up"):
                problemas.append(f"estado esperado up/up, encontrado {real['estado']}/{real['protocolo']}")
        a.agregar(f"Vlan{m['vlan']} gestion (show ip interface brief)", problemas, "ip-interface-brief.txt")
    if ver:
        v = version_ios(ver)
        versiones[equipo] = v
        a.agregar("Version de IOS identificada", [] if v else ["no se encontro la version en show version"], "version.txt")
    return a.filas


def auditar_router(equipo, diseno, vlans, carpeta, versiones):
    a = Auditoria(equipo, carpeta)
    config = a.texto("running-config.txt")
    ipb = a.texto("ip-interface-brief.txt")
    ver = a.texto("version.txt")
    troncal = diseno["trunk_interface"]["name"]
    if config:
        interfaces = parsear_interfaces(config)
        a.agregar("Hostname coincide con el diseno",
                  [] if hostname(config) == diseno["hostname"] else [f"esperado {diseno['hostname']}, encontrado {hostname(config)}"],
                  "running-config.txt")
        desc = valor(interfaces.get(troncal, []), "description ")
        a.agregar(f"{troncal} troncal (descripcion)",
                  [] if desc == diseno["trunk_interface"]["description"] else [f"esperada '{diseno['trunk_interface']['description']}', encontrada '{desc}'"],
                  "running-config.txt")
        for v in vlans:
            sub = f"{troncal}.{v['id']}"
            lineas, problemas = interfaces.get(sub), []
            if lineas is None:
                problemas.append("la subinterfaz no existe")
            else:
                encap = f"encapsulation dot1Q {v['id']}" + (" native" if v["id"] == 99 else "")
                if encap not in lineas:
                    problemas.append(f"falta '{encap}'")
                ip = valor(lineas, "ip address ")
                if ip != f"{v['gateway']} {v['mask']}":
                    problemas.append(f"ip esperada {v['gateway']} {v['mask']}, encontrada {ip}")
            a.agregar(f"Subinterfaz {sub} gateway VLAN {v['id']}", problemas, "running-config.txt")
    if ipb:
        info = parsear_ip_brief(ipb)
        for v in vlans:
            sub, problemas = f"{troncal}.{v['id']}", []
            real = info.get(sub)
            if real is None:
                problemas.append("no aparece en show ip interface brief")
            elif (real["ip"], real["estado"], real["protocolo"]) != (v["gateway"], "up", "up"):
                problemas.append(f"esperado {v['gateway']} up/up, encontrado {real['ip']} {real['estado']}/{real['protocolo']}")
            a.agregar(f"{sub} estado (show ip interface brief)", problemas, "ip-interface-brief.txt")
    if ver:
        v = version_ios(ver)
        versiones[equipo] = v
        a.agregar("Version de IOS identificada", [] if v else ["no se encontro la version en show version"], "version.txt")
    return a.filas


def main():
    ap = argparse.ArgumentParser(description="Audita router y switches con la evidencia de Ansible.")
    ap.add_argument("--respaldos", type=Path, default=RAIZ / "respaldos")
    ap.add_argument("--csv", type=Path, default=RAIZ / "evidencias" / "p3_auditoria_flota.csv")
    args = ap.parse_args()

    vlans = cargar_yaml(RAIZ / "variables" / "vlans.yml")["vlans"]
    filas, versiones = [], {}
    print(f"Datos leidos: variables/*.yml y {args.respaldos}/<equipo>/ (running-config, version, vlan-brief, interfaces-trunk, ip-interface-brief)")
    for equipo, datos in inventario().items():
        diseno = cargar_yaml(RAIZ / "variables" / f"{equipo}.yml")
        auditar_equipo = auditar_router if datos["grupo"] == "routers" else auditar_switch
        filas += auditar_equipo(equipo, diseno, vlans, args.respaldos / equipo, versiones)

    switches = {e: v for e, v in versiones.items() if inventario()[e]["grupo"] == "switches"}
    if len(set(switches.values())) > 1:
        filas.append({"equipo": "FLOTA", "condicion": "Version de IOS homogenea entre switches", "resultado": "NO CUMPLE",
                      "evidencia": "version.txt", "detalle": ", ".join(f"{e}={v}" for e, v in switches.items())})
    elif switches:
        filas.append({"equipo": "FLOTA", "condicion": "Version de IOS homogenea entre switches", "resultado": "CUMPLE",
                      "evidencia": "version.txt", "detalle": ""})

    args.csv.parent.mkdir(parents=True, exist_ok=True)
    with open(args.csv, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=["equipo", "condicion", "resultado", "evidencia", "detalle"])
        w.writeheader()
        w.writerows(filas)

    print(f"\n{'EQUIPO':<16}{'RESULTADO':<11}{'EVIDENCIA':<24}CONDICION")
    for r in filas:
        print(f"{r['equipo']:<16}{r['resultado']:<11}{r['evidencia']:<24}{r['condicion']}")
        if r["detalle"]:
            print(f"{'':<16}  -> {r['detalle']}")
    fallos = sum(r["resultado"] == "NO CUMPLE" for r in filas)
    print(f"\nResumen: {len(filas) - fallos} de {len(filas)} condiciones cumplen; {fallos} no cumplen.")
    print(f"CSV generado: {args.csv}")
    return 1 if fallos else 0


if __name__ == "__main__":
    sys.exit(main())
