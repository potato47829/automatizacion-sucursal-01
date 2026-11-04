#!/usr/bin/env python3
"""Prototipo 5: mide la conectividad de gestion desde el servidor de automatizacion.

Ejecuta 10 pings ICMP (comando ping local) hacia cada equipo del inventario,
guarda evidencias/mediciones_conectividad.csv y clasifica cada destino:
CUMPLE = sin perdida y latencia promedio <= 50 ms. No abre SSH ni configura nada.
"""
import argparse
import csv
import os
import re
import subprocess
import sys
from datetime import datetime
from pathlib import Path

from comun import RAIZ, inventario

CAMPOS = ["fecha", "destino", "ip", "enviados", "recibidos", "perdida_pct",
          "lat_min_ms", "lat_prom_ms", "lat_max_ms", "clasificacion"]


def interpretar(salida):
    """Extrae enviados, recibidos y latencias de la salida de ping (en ingles)."""
    m = re.search(r"(\d+) packets transmitted, (\d+) (?:packets )?received", salida)
    enviados, recibidos = (int(m.group(1)), int(m.group(2))) if m else (0, 0)
    t = re.search(r"= ([\d.]+)/([\d.]+)/([\d.]+)", salida)
    minimo, promedio, maximo = (float(x) for x in t.groups()) if t else (None, None, None)
    return enviados, recibidos, minimo, promedio, maximo


def medir(ip, cantidad):
    entorno = dict(os.environ, LC_ALL="C")
    proceso = subprocess.run(["ping", "-c", str(cantidad), "-i", "0.2", "-W", "2", ip],
                             capture_output=True, text=True, env=entorno)
    return interpretar(proceso.stdout)


def main():
    ap = argparse.ArgumentParser(description="Mide latencia y perdida hacia los equipos de la sucursal.")
    ap.add_argument("--cantidad", type=int, default=10, help="pings por destino")
    ap.add_argument("--umbral", type=float, default=50.0, help="latencia promedio maxima en ms")
    ap.add_argument("--csv", type=Path, default=RAIZ / "evidencias" / "mediciones_conectividad.csv")
    args = ap.parse_args()

    equipos = inventario()
    print(f"Datos leidos: inventario/hosts.yml ({len(equipos)} destinos). "
          f"Condicion: perdida 0% y latencia promedio <= {args.umbral:g} ms")
    filas = []
    for nombre, datos in equipos.items():
        enviados, recibidos, mn, prom, mx = medir(datos["ip"], args.cantidad)
        perdida = round(100 * (enviados - recibidos) / enviados, 1) if enviados else 100.0
        cumple = enviados > 0 and perdida == 0 and prom is not None and prom <= args.umbral
        filas.append({"fecha": datetime.now().strftime("%Y-%m-%d %H:%M:%S"), "destino": nombre, "ip": datos["ip"],
                      "enviados": enviados, "recibidos": recibidos, "perdida_pct": perdida,
                      "lat_min_ms": mn, "lat_prom_ms": prom, "lat_max_ms": mx,
                      "clasificacion": "CUMPLE" if cumple else "NO CUMPLE"})

    nuevo = not args.csv.exists()
    args.csv.parent.mkdir(parents=True, exist_ok=True)
    with open(args.csv, "a", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=CAMPOS)
        if nuevo:
            w.writeheader()
        w.writerows(filas)

    print(f"\n{'DESTINO':<16}{'IP':<16}{'ENV':>4}{'REC':>5}{'PERD%':>7}{'MIN':>8}{'PROM':>8}{'MAX':>8}  RESULTADO")
    for r in filas:
        lat = [("-" if r[k] is None else f"{r[k]:.2f}") for k in ("lat_min_ms", "lat_prom_ms", "lat_max_ms")]
        print(f"{r['destino']:<16}{r['ip']:<16}{r['enviados']:>4}{r['recibidos']:>5}{r['perdida_pct']:>7}"
              f"{lat[0]:>8}{lat[1]:>8}{lat[2]:>8}  {r['clasificacion']}")
        if r["clasificacion"] == "NO CUMPLE":
            motivo = "sin respuesta" if r["recibidos"] == 0 else (
                "hay perdida de paquetes" if r["perdida_pct"] else f"latencia promedio sobre {args.umbral:g} ms")
            print(f"{'':<16}  -> {motivo}")
    fallos = sum(r["clasificacion"] == "NO CUMPLE" for r in filas)
    print(f"\nResumen: {len(filas) - fallos} de {len(filas)} destinos cumplen. CSV: {args.csv}")
    return 1 if fallos else 0


if __name__ == "__main__":
    sys.exit(main())
