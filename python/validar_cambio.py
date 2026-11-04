#!/usr/bin/env python3
"""Prototipo 1: validacion antes y despues de un cambio aprobado.

Lee: evidencias/antes y evidencias/despues (obtenidas con Ansible),
     datos/cambio_aprobado.yml y el diseno de variables/*.yml.
No se conecta a ningun equipo.
"""
import argparse
import sys
from pathlib import Path

from comun import (RAIZ, cargar_yaml, corta, hostname, inventario, leer,
                   parsear_interfaces, parsear_ip_brief, parsear_rutas,
                   parsear_trunk, parsear_vlans, valor)

OK_CAMBIO = "CAMBIO APLICADO CORRECTAMENTE"
OK_CRITICO = "ELEMENTO CRITICO SIN CAMBIOS"
DIFERENCIA = "DIFERENCIA DETECTADA"


def bloque(carpeta, interfaz, ignorar=None):
    """Lineas de una interfaz en la running-config (sin el atributo ignorado)."""
    texto = leer(carpeta / "running-config.txt")
    if texto is None:
        return None
    lineas = parsear_interfaces(texto).get(interfaz)
    if lineas is None:
        return None
    return [ln for ln in lineas if not (ignorar and ln.startswith(ignorar + " "))]


def elementos_criticos(equipo, rol, diseno, vlans, cambios):
    """Devuelve [(nombre, funcion)] ; cada funcion recibe una carpeta y devuelve un valor."""
    ign = {(c["equipo"], c["interfaz"]): c["atributo"] for c in cambios}
    lista = []
    if rol == "switches":
        for v in vlans:
            lista.append((f"VLAN {v['id']} ({v['name']}) existe, nombre y estado",
                          lambda d, v=v: (parsear_vlans(leer(d / "vlan-brief.txt") or "").get(v["id"]))))
        for t in diseno["trunks"]:
            i = t["interface"]
            lista.append((f"{i} troncal: configuracion", lambda d, i=i: bloque(d, i)))
            lista.append((f"{i} troncal: estado operativo (show interfaces trunk)",
                          lambda d, i=i: parsear_trunk(leer(d / "interfaces-trunk.txt") or "").get(corta(i))))
        for p in diseno["access_ports"]:
            i = p["interface"]
            lista.append((f"{i} acceso VLAN {p['vlan']}: configuracion",
                          lambda d, i=i: bloque(d, i, ign.get((equipo, i)))))
        v = diseno["management"]["vlan"]
        lista.append((f"Vlan{v} gestion {diseno['management']['ip']}: configuracion",
                      lambda d, v=v: bloque(d, f"Vlan{v}")))
        lista.append((f"Vlan{v} gestion: estado (show ip interface brief)",
                      lambda d, v=v: parsear_ip_brief(leer(d / "ip-interface-brief.txt") or "").get(f"Vlan{v}")))
    else:
        t = diseno["trunk_interface"]["name"]
        lista.append((f"{t} troncal fisico: configuracion", lambda d: bloque(d, t)))
        for v in vlans:
            sub = f"{t}.{v['id']}"
            lista.append((f"{sub} gateway VLAN {v['id']}: configuracion", lambda d, s=sub: bloque(d, s)))
            lista.append((f"{sub} gateway VLAN {v['id']}: estado (show ip interface brief)",
                          lambda d, s=sub: parsear_ip_brief(leer(d / "ip-interface-brief.txt") or "").get(s)))
    lista.append(("Hostname", lambda d: hostname(leer(d / "running-config.txt") or "")))
    lista.append(("Rutas (show ip route)", lambda d: sorted(parsear_rutas(leer(d / "ip-route.txt") or ""))))
    return lista


def validar_cambios(cambios, antes, despues):
    resultados = []
    for c in cambios:
        equipo, interfaz, attr = c["equipo"], c["interfaz"], c["atributo"]
        nombre = f"{equipo} {interfaz} {attr}: '{c['valor_antes']}' -> '{c['valor_despues']}'"
        ba = bloque(antes / equipo, interfaz)
        bd = bloque(despues / equipo, interfaz)
        problemas = []
        if ba is None or bd is None:
            problemas.append("no hay evidencia de la interfaz antes o despues")
        else:
            va, vd = valor(ba, attr + " "), valor(bd, attr + " ")
            if va != c["valor_antes"]:
                problemas.append(f"valor ANTES esperado '{c['valor_antes']}', encontrado '{va}'")
            if vd != c["valor_despues"]:
                problemas.append(f"valor DESPUES esperado '{c['valor_despues']}', encontrado '{vd}'")
            if bloque(antes / equipo, interfaz, attr) != bloque(despues / equipo, interfaz, attr):
                problemas.append("cambiaron otras lineas de la interfaz, ademas del atributo aprobado")
        resultados.append((nombre, problemas))
    return resultados


def main():
    ap = argparse.ArgumentParser(description="Valida un cambio comparando evidencias antes/despues.")
    ap.add_argument("--antes", type=Path, default=RAIZ / "evidencias" / "antes")
    ap.add_argument("--despues", type=Path, default=RAIZ / "evidencias" / "despues")
    ap.add_argument("--cambio", type=Path, default=RAIZ / "datos" / "cambio_aprobado.yml")
    args = ap.parse_args()

    cambio = cargar_yaml(args.cambio)
    cambios = cambio["cambios"]
    vlans = cargar_yaml(RAIZ / "variables" / "vlans.yml")["vlans"]
    print(f"PROTOTIPO 1 - {cambio['id_cambio']}: {cambio['descripcion']}")
    print(f"Datos leidos: {args.antes}, {args.despues}, {args.cambio}, variables/*.yml")

    fallos = 0
    print("\n-- Cambio solicitado")
    for nombre, problemas in validar_cambios(cambios, args.antes, args.despues):
        fallos += bool(problemas)
        print(f"  [{DIFERENCIA if problemas else OK_CAMBIO}] {nombre}")
        for p in problemas:
            print(f"      - {p}")

    print("\n-- Elementos criticos (deben ser iguales antes y despues)")
    for equipo, datos in inventario().items():
        diseno = cargar_yaml(RAIZ / "variables" / f"{equipo}.yml")
        print(f"  {equipo}")
        for nombre, funcion in elementos_criticos(equipo, datos["grupo"], diseno, vlans, cambios):
            a, d = funcion(args.antes / equipo), funcion(args.despues / equipo)
            if a is None or d is None:
                estado, detalle = DIFERENCIA, "falta evidencia o el elemento no aparece"
            elif a != d:
                estado, detalle = DIFERENCIA, f"antes={a}  despues={d}"
            else:
                estado, detalle = OK_CRITICO, None
            fallos += estado == DIFERENCIA
            print(f"    [{estado}] {nombre}")
            if detalle:
                print(f"        - {detalle}")

    print("\nResultado: " + ("se detectaron diferencias, revisar el cambio" if fallos
                           else "el cambio se aplico y los elementos criticos se conservaron"))
    return 1 if fallos else 0


if __name__ == "__main__":
    sys.exit(main())
