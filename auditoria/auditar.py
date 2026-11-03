#!/usr/bin/env python3
"""Auditoría de cumplimiento de la Sucursal 01.

Lee el diseño esperado (variables/*.yml) y la evidencia que dejó Ansible
(respaldos/<equipo>/running-config.txt y vlan-brief.txt).
No abre sesiones SSH ni modifica ningún dispositivo.
"""
import argparse
import re
import sys
from pathlib import Path

import yaml

RAIZ = Path(__file__).resolve().parent.parent
ESTADOS_VLAN = r"(active|act/unsup|suspended|act/lshut|sus/lshut)"


# ---------- Lectura de archivos ----------
def cargar_yaml(ruta):
    with open(ruta, encoding="utf-8") as archivo:
        return yaml.safe_load(archivo)


def leer_texto(ruta):
    try:
        return Path(ruta).read_text(encoding="utf-8")
    except FileNotFoundError:
        return None


# ---------- Análisis de la evidencia ----------
def parsear_vlans(texto):
    """Convierte la salida de 'show vlan brief' en {id: {nombre, estado}}."""
    vlans = {}
    for linea in texto.splitlines():
        m = re.match(rf"^(\d+)\s+(.+?)\s+{ESTADOS_VLAN}\b", linea)
        if m:
            vlans[int(m.group(1))] = {"nombre": m.group(2).strip(), "estado": m.group(3)}
    return vlans


def parsear_interfaces(texto):
    """Convierte la running-config en {interfaz: [líneas del bloque]}."""
    bloques, actual = {}, None
    for linea in texto.splitlines():
        if linea.startswith("interface "):
            actual = linea.split(None, 1)[1].strip()
            bloques[actual] = []
        elif linea.startswith(" ") and actual:
            bloques[actual].append(linea.strip())
        else:
            actual = None
    return bloques


def valor(lineas, prefijo):
    for linea in lineas:
        if linea.startswith(prefijo):
            return linea[len(prefijo):].strip()
    return None


def expandir(texto):
    """'10,20,30-32' -> {10, 20, 30, 31, 32}"""
    vlans = set()
    for parte in texto.split(","):
        parte = parte.strip()
        if "-" in parte:
            inicio, fin = parte.split("-")
            vlans.update(range(int(inicio), int(fin) + 1))
        elif parte:
            vlans.add(int(parte))
    return vlans


def vlans_permitidas(lineas):
    """VLAN permitidas en un troncal; None significa 'todas' (valor por defecto)."""
    prefijo = "switchport trunk allowed vlan "
    permitidas = None
    for linea in lineas:
        if not linea.startswith(prefijo):
            continue
        resto = linea[len(prefijo):].strip()
        if resto.startswith("add "):
            permitidas = (permitidas or set()) | expandir(resto[4:])
        elif resto == "none":
            permitidas = set()
        elif resto == "all":
            permitidas = None
        else:
            permitidas = expandir(resto)
    return permitidas


def fmt(vlans):
    return ",".join(str(v) for v in sorted(vlans))


# ---------- Auditorías ----------
def auditar_vlans(vlans_esperadas, vlans_reales):
    resultados = []
    for vlan in vlans_esperadas:
        elemento = f"VLAN {vlan['id']} ({vlan['name']})"
        real = vlans_reales.get(vlan["id"])
        problemas = []
        if real is None:
            problemas.append("la VLAN no existe")
        else:
            if real["nombre"] != vlan["name"]:
                problemas.append(f"nombre esperado '{vlan['name']}', encontrado '{real['nombre']}'")
            if real["estado"] != "active":
                problemas.append(f"estado esperado 'active', encontrado '{real['estado']}'")
        resultados.append((elemento, problemas))
    return resultados


def auditar_troncales(troncales, interfaces):
    resultados = []
    for troncal in troncales:
        nombre = troncal["interface"]
        elemento = f"{nombre} troncal"
        lineas = interfaces.get(nombre)
        problemas = []
        if lineas is None:
            problemas.append("la interfaz no aparece en la configuración")
        else:
            modo = valor(lineas, "switchport mode ")
            if modo != "trunk":
                problemas.append(f"modo esperado 'trunk', encontrado '{modo or 'no definido'}'")
            nativa = valor(lineas, "switchport trunk native vlan ") or "1"
            if nativa != str(troncal["native_vlan"]):
                problemas.append(f"VLAN nativa esperada {troncal['native_vlan']}, encontrada {nativa}")
            esperadas = set(troncal["allowed_vlans"])
            permitidas = vlans_permitidas(lineas)
            if permitidas != esperadas:
                encontradas = "todas (valor por defecto)" if permitidas is None else fmt(permitidas)
                problemas.append(f"VLAN permitidas esperadas {fmt(esperadas)}, encontradas {encontradas}")
            descripcion = valor(lineas, "description ")
            if descripcion != troncal["description"]:
                problemas.append(
                    f"descripción esperada '{troncal['description']}', encontrada '{descripcion or 'sin descripción'}'"
                )
        resultados.append((elemento, problemas))
    return resultados


def auditar_acceso(puertos, interfaces):
    resultados = []
    for puerto in puertos:
        nombre = puerto["interface"]
        elemento = f"{nombre} acceso VLAN {puerto['vlan']}"
        lineas = interfaces.get(nombre)
        problemas = []
        if lineas is None:
            problemas.append("la interfaz no aparece en la configuración")
        else:
            modo = valor(lineas, "switchport mode ")
            if modo != "access":
                problemas.append(f"modo esperado 'access', encontrado '{modo or 'no definido'}'")
            vlan = valor(lineas, "switchport access vlan ") or "1"
            if vlan != str(puerto["vlan"]):
                problemas.append(f"VLAN de acceso esperada {puerto['vlan']}, encontrada {vlan}")
            descripcion = valor(lineas, "description ")
            if descripcion != puerto["description"]:
                problemas.append(
                    f"descripción esperada '{puerto['description']}', encontrada '{descripcion or 'sin descripción'}'"
                )
        resultados.append((elemento, problemas))
    return resultados


def auditar_equipo(diseno, vlans, carpeta):
    resultados = []
    brief = leer_texto(carpeta / "vlan-brief.txt")
    config = leer_texto(carpeta / "running-config.txt")

    if brief is None:
        resultados.append(("Evidencia de VLAN", [f"no existe {carpeta / 'vlan-brief.txt'}"]))
    else:
        resultados += auditar_vlans(vlans, parsear_vlans(brief))

    if config is None:
        resultados.append(("Evidencia de configuración", [f"no existe {carpeta / 'running-config.txt'}"]))
    else:
        interfaces = parsear_interfaces(config)
        resultados += auditar_troncales(diseno["trunks"], interfaces)
        resultados += auditar_acceso(diseno["access_ports"], interfaces)
    return resultados


# ---------- Programa principal ----------
def main():
    parser = argparse.ArgumentParser(description="Audita la evidencia de la Sucursal 01 contra el diseño YAML.")
    parser.add_argument("--variables", type=Path, default=RAIZ / "variables")
    parser.add_argument("--respaldos", type=Path, default=RAIZ / "respaldos")
    args = parser.parse_args()

    archivos = sorted(args.variables.glob("SW-*.yml"))
    if not archivos:
        print(f"No se encontraron archivos SW-*.yml en {args.variables}")
        return 2

    vlans = cargar_yaml(args.variables / "vlans.yml")["vlans"]
    total = fallos = 0

    for archivo in archivos:
        diseno = cargar_yaml(archivo)
        host = diseno["hostname"]
        print(f"\n=== {host} ===")
        for elemento, problemas in auditar_equipo(diseno, vlans, args.respaldos / host):
            total += 1
            estado = "CUMPLE" if not problemas else "NO CUMPLE"
            fallos += bool(problemas)
            print(f"  [{estado:<9}] {elemento}")
            for problema in problemas:
                print(f"      - {problema}")

    print(f"\nResumen: {total - fallos} de {total} elementos cumplen; {fallos} no cumplen.")
    return 1 if fallos else 0


if __name__ == "__main__":
    sys.exit(main())
