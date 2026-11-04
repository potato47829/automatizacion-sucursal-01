#!/usr/bin/env python3
"""Funciones compartidas por los prototipos (solo leen archivos locales)."""
import re
import sys
from pathlib import Path

import yaml

RAIZ = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(RAIZ / "auditoria"))
from auditar import parsear_interfaces, parsear_vlans, valor  # noqa: E402,F401


def cargar_yaml(ruta):
    with open(ruta, encoding="utf-8") as archivo:
        return yaml.safe_load(archivo)


def leer(ruta):
    try:
        return Path(ruta).read_text(encoding="utf-8")
    except FileNotFoundError:
        return None


def corta(nombre):
    """GigabitEthernet0/1 -> Gi0/1 (formato de show interfaces trunk)."""
    return nombre.replace("GigabitEthernet", "Gi")


def hostname(config):
    m = re.search(r"^hostname (\S+)", config, re.M)
    return m.group(1) if m else None


def inventario(raiz=RAIZ):
    """{equipo: {'grupo': routers|switches, 'ip': ansible_host}} desde hosts.yml."""
    grupos = cargar_yaml(raiz / "inventario" / "hosts.yml")["all"]["children"]
    equipos = {}
    for grupo, contenido in grupos.items():
        for nombre, datos in contenido["hosts"].items():
            equipos[nombre] = {"grupo": grupo, "ip": datos["ansible_host"]}
    return equipos


def parsear_trunk(texto):
    """show interfaces trunk -> {Gi0/0: {modo, estado, nativa, permitidas}}."""
    info, seccion = {}, None
    for linea in texto.splitlines():
        p = linea.split()
        if not p:
            continue
        if p[0] == "Port":
            if "Mode" in linea:
                seccion = "modo"
            elif "allowed on trunk" in linea:
                seccion = "permitidas"
            else:
                seccion = None
        elif seccion == "modo" and len(p) >= 5:
            info.setdefault(p[0], {}).update(modo=p[1], estado=p[3], nativa=p[4])
        elif seccion == "permitidas" and len(p) >= 2:
            info.setdefault(p[0], {})["permitidas"] = p[1]
    return info


def parsear_ip_brief(texto):
    """show ip interface brief -> {interfaz: {ip, estado, protocolo}}."""
    patron = re.compile(r"^(\S+)\s+(\S+)\s+(?:YES|NO)\s+\S+\s+(.+?)\s+(up|down)\s*$")
    interfaces = {}
    for linea in texto.splitlines():
        m = patron.match(linea)
        if m:
            interfaces[m.group(1)] = {"ip": m.group(2), "estado": m.group(3), "protocolo": m.group(4)}
    return interfaces


def parsear_rutas(texto):
    """show ip route -> {(codigo, prefijo, destino)} (solo rutas, sin tiempos)."""
    patron = re.compile(r"^\s*([A-Z][A-Z0-9]{0,2}\*?)\s+(\d+\.\d+\.\d+\.\d+(?:/\d+)?)\s+(.*)$")
    rutas = set()
    for linea in texto.splitlines():
        m = patron.match(linea)
        if not m:
            continue
        resto = m.group(3)
        if " via " in resto:
            destino = resto.split(" via ")[1].split()[0].strip(",")
        elif "directly connected" in resto:
            destino = resto.split(",")[-1].strip()
        else:
            destino = resto.strip()
        rutas.add((m.group(1), m.group(2), destino))
    return rutas
