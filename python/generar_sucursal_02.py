#!/usr/bin/env python3
"""Prototipo 2: genera el plan de direccionamiento de la Sucursal 02.

Lee datos/sucursal_02_entrada.yml, calcula una subred por VLAN sin solapamiento
y escribe variables/sucursal_02_generada.yml para usarlo luego con Ansible.
No configura ningun equipo.
"""
import argparse
import ipaddress
import sys
from pathlib import Path

import yaml

RAIZ = Path(__file__).resolve().parent.parent


def prefijo_para(dispositivos):
    """Prefijo minimo para dispositivos + 1 gateway + red + broadcast."""
    direcciones = dispositivos + 1 + 2
    return 32 - (direcciones - 1).bit_length()


def asignar(bloque, vlans):
    """Asigna subredes alineadas, de la mas grande a la mas pequena."""
    base = int(bloque.network_address)
    fin = int(bloque.broadcast_address)
    cursor = base
    asignadas = {}
    for vlan in sorted(vlans, key=lambda v: prefijo_para(v["dispositivos"])):
        tam = 2 ** (32 - prefijo_para(vlan["dispositivos"]))
        cursor = (cursor + tam - 1) // tam * tam        # alinear al tamano de la subred
        if cursor + tam - 1 > fin:
            raise ValueError(f"el bloque {bloque} no alcanza para la VLAN {vlan['id']}")
        asignadas[vlan["id"]] = ipaddress.ip_network((cursor, prefijo_para(vlan["dispositivos"])))
        cursor += tam
    return asignadas


def main():
    ap = argparse.ArgumentParser(description="Genera variables YAML para la Sucursal 02.")
    ap.add_argument("--entrada", type=Path, default=RAIZ / "datos" / "sucursal_02_entrada.yml")
    ap.add_argument("--salida", type=Path, default=RAIZ / "variables" / "sucursal_02_generada.yml")
    args = ap.parse_args()

    entrada = yaml.safe_load(args.entrada.read_text(encoding="utf-8"))
    bloque = ipaddress.ip_network(entrada["bloque_disponible"])
    print(f"Datos leidos: {args.entrada}")
    print(f"Bloque disponible {bloque} ({bloque.num_addresses} direcciones); "
          f"{len(entrada['vlans'])} VLAN requeridas")

    redes = asignar(bloque, entrada["vlans"])
    lista = sorted(redes.values(), key=lambda r: r.network_address)
    solapadas = [(a, b) for i, a in enumerate(lista) for b in lista[i + 1:] if a.overlaps(b)]

    vlans = []
    for v in sorted(entrada["vlans"], key=lambda x: x["id"]):
        red = redes[v["id"]]
        vlans.append({
            "id": v["id"], "name": v["nombre"], "network": str(red),
            "mask": str(red.netmask), "prefix": red.prefixlen,
            "gateway": str(red.network_address + 1),
            "hosts_previstos": v["dispositivos"], "hosts_utilizables": red.num_addresses - 2,
        })
    generado = {"sucursal": entrada["sucursal"], "bloque": str(bloque), "native_vlan": 99, "vlans": vlans}
    args.salida.parent.mkdir(parents=True, exist_ok=True)
    with open(args.salida, "w", encoding="utf-8") as f:
        f.write("# Generado por python/generar_sucursal_02.py. No editar a mano.\n")
        yaml.safe_dump(generado, f, sort_keys=False, allow_unicode=True)

    print(f"\nPLAN DE DIRECCIONAMIENTO {entrada['sucursal']}")
    print(f"{'VLAN':<5}{'Nombre':<16}{'Red':<16}{'Mascara':<16}{'Gateway':<12}{'Previstos':>10}{'Utilizables':>13}")
    for v in vlans:
        print(f"{v['id']:<5}{v['name']:<16}{v['network']:<16}{v['mask']:<16}{v['gateway']:<12}"
              f"{v['hosts_previstos']:>10}{v['hosts_utilizables']:>13}")
    usadas = sum(r.num_addresses for r in lista)
    ultima = lista[-1].broadcast_address
    libres = list(ipaddress.summarize_address_range(ultima + 1, bloque.broadcast_address)) if ultima < bloque.broadcast_address else []
    print(f"\nUso del bloque: {usadas} de {bloque.num_addresses} direcciones ({usadas / bloque.num_addresses:.1%})")
    print("Libre: " + (", ".join(str(r) for r in libres) or "nada"))
    print("Verificacion de solapamiento: " + ("OK, sin solapamientos" if not solapadas else f"ERROR {solapadas}"))
    print(f"Archivo generado: {args.salida}")
    return 1 if solapadas else 0


if __name__ == "__main__":
    sys.exit(main())
