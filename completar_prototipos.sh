#!/usr/bin/env bash
# Completa el repositorio con los 5 prototipos de Python. Ejecutar desde la raiz del repositorio.
set -euo pipefail
[ -f ansible.cfg ] || { echo "ERROR: ejecuta este script en la raiz del repositorio (donde esta ansible.cfg)"; exit 1; }
mkdir -p python datos variables evidencias documentacion

# --- Documentacion: mover docs/ y quitar la clave en texto plano ---
if [ -f docs/configuracion-inicial.md ]; then
  mv docs/configuracion-inicial.md documentacion/configuracion-inicial.md
  rmdir docs 2>/dev/null || true
fi
if [ -f documentacion/configuracion-inicial.md ]; then
  sed -i 's/\(privilege 15 secret\) .*/\1 <CLAVE_EN_VAULT>/; s/19ss2/192/' documentacion/configuracion-inicial.md
fi
sed -i 's#descrita en docs/#descrita en documentacion/#' README.md
echo 'Creando python/comun.py'
cat > python/comun.py << '__FIN__'
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
__FIN__
echo 'Creando python/validar_cambio.py'
cat > python/validar_cambio.py << '__FIN__'
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
__FIN__
echo 'Creando python/generar_sucursal_02.py'
cat > python/generar_sucursal_02.py << '__FIN__'
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
__FIN__
echo 'Creando python/auditar_flota.py'
cat > python/auditar_flota.py << '__FIN__'
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
__FIN__
echo 'Creando python/validar_inventario.py'
cat > python/validar_inventario.py << '__FIN__'
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
__FIN__
echo 'Creando python/medir_conectividad.py'
cat > python/medir_conectividad.py << '__FIN__'
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
__FIN__
echo 'Creando datos/cambio_aprobado.yml'
cat > datos/cambio_aprobado.yml << '__FIN__'
---
# Cambio aprobado CAMBIO-001: actualizar la descripcion de un puerto de acceso.
# No es disruptivo: no modifica VLAN, troncales, gestion ni rutas.
id_cambio: CAMBIO-001
descripcion: Identificar al usuario de PC1 en la descripcion del puerto
cambios:
  - equipo: SW-SUC-01-CORE
    interfaz: GigabitEthernet0/2
    atributo: description
    valor_antes: ACCESO VLAN10 PC1
    valor_despues: ACCESO VLAN10 PC1 CAMBIO-001
__FIN__
echo 'Creando datos/sucursal_02_entrada.yml'
cat > datos/sucursal_02_entrada.yml << '__FIN__'
---
sucursal: SUCURSAL-02
bloque_disponible: 10.20.0.0/23
vlans:
  - {id: 10, nombre: ADMINISTRACION, dispositivos: 50}
  - {id: 20, nombre: OPERACION, dispositivos: 25}
  - {id: 99, nombre: GESTION, dispositivos: 10}
__FIN__
echo 'Creando datos/ipam_sucursal_01.json'
cat > datos/ipam_sucursal_01.json << '__FIN__'
{
  "fuente": "IPAM simulado (respuesta tipo API)",
  "sitio": "SUCURSAL-01",
  "prefijos": [
    {"vlan": 10, "nombre": "USUARIOS_VLAN10", "red": "192.168.10.0/24", "gateway": "192.168.10.1"},
    {"vlan": 20, "nombre": "USUARIOS_VLAN20", "red": "192.168.20.0/24", "gateway": "192.168.20.1"},
    {"vlan": 99, "nombre": "GESTION", "red": "192.168.99.0/24", "gateway": "192.168.99.1"}
  ],
  "dispositivos": [
    {"nombre": "R-SUC-01", "funcion": "router", "direccion_gestion": "192.168.100.1"},
    {"nombre": "SW-SUC-01-CORE", "funcion": "switch", "direccion_gestion": "192.168.99.2"},
    {"nombre": "SW-SUC-01-ACC1", "funcion": "switch", "direccion_gestion": "192.168.99.3"}
  ]
}
__FIN__
echo 'Creando datos/ipam_sucursal_01_con_diferencias.json'
cat > datos/ipam_sucursal_01_con_diferencias.json << '__FIN__'
{
  "fuente": "IPAM simulado (respuesta tipo API)",
  "sitio": "SUCURSAL-01",
  "prefijos": [
    {
      "vlan": 10,
      "nombre": "USUARIOS_VLAN10",
      "red": "192.168.10.0/24",
      "gateway": "192.168.10.1"
    },
    {
      "vlan": 20,
      "nombre": "USUARIOS_VLAN20",
      "red": "192.168.20.0/24",
      "gateway": "192.168.20.254"
    },
    {
      "vlan": 99,
      "nombre": "GESTION",
      "red": "192.168.98.0/24",
      "gateway": "192.168.99.1"
    }
  ],
  "dispositivos": [
    {
      "nombre": "SW-SUC-01-CORE",
      "funcion": "switch",
      "direccion_gestion": "192.168.99.22"
    },
    {
      "nombre": "SW-SUC-01-ACC1",
      "funcion": "router",
      "direccion_gestion": "192.168.99.3"
    },
    {
      "nombre": "SW-SUC-01-ACC2",
      "funcion": "switch",
      "direccion_gestion": "192.168.99.4"
    }
  ]
}
__FIN__
echo 'Creando playbooks/03_respaldos.yml'
cat > playbooks/03_respaldos.yml << '__FIN__'
---
# Obtiene la evidencia de los tres equipos y la guarda en el servidor.
# Por defecto va a respaldos/. Para otra carpeta:  -e destino=evidencias/antes
- name: Obtener y guardar la evidencia de los equipos
  hosts: routers:switches
  gather_facts: false
  vars:
    destino: respaldos
    carpeta: "{{ playbook_dir }}/../{{ destino }}/{{ inventory_hostname }}"
    comandos_comunes:
      - {cmd: show running-config, archivo: running-config.txt}
      - {cmd: show version, archivo: version.txt}
      - {cmd: show ip interface brief, archivo: ip-interface-brief.txt}
      - {cmd: show ip route, archivo: ip-route.txt}
    comandos_switch:
      - {cmd: show vlan brief, archivo: vlan-brief.txt}
      - {cmd: show interfaces trunk, archivo: interfaces-trunk.txt}
    comandos: "{{ comandos_comunes + (comandos_switch if inventory_hostname in groups['switches'] else []) }}"
    # Se descartan usuarios/secretos y datos que cambian solos (tiempo encendido)
    filtro: '^(username |enable (secret|password))|uptime is|System restarted at'

  tasks:
    - name: Ejecutar los comandos de evidencia
      cisco.ios.ios_command:
        commands: "{{ comandos | map(attribute='cmd') | list }}"
      register: salida

    - name: Crear la carpeta del equipo
      ansible.builtin.file:
        path: "{{ carpeta }}"
        state: directory
        mode: "0755"
      delegate_to: localhost

    - name: Guardar cada salida como archivo de texto
      ansible.builtin.copy:
        content: "{{ item.1.splitlines() | reject('search', filtro) | join('\n') }}\n"
        dest: "{{ carpeta }}/{{ item.0.archivo }}"
        mode: "0644"
      loop: "{{ comandos | zip(salida.stdout) | list }}"
      loop_control:
        label: "{{ item.0.archivo }}"
      delegate_to: localhost
__FIN__
echo 'Creando documentacion/README.md'
cat > documentacion/README.md << '__FIN__'
# Prototipos de Python aplicados a redes - Sucursal 01

Esta documentación continúa la automatización de la Sucursal 01 (ver README.md
de la raíz). Los cinco prototipos **analizan, organizan o producen información**;
**Ansible** sigue siendo quien consulta, configura y obtiene las evidencias de los
equipos. Ningún programa Python se conecta por SSH ni aplica configuración.
No hay contraseñas ni secretos en el repositorio: las credenciales están en el vault
(`.vault_pass` no se sube) y los respaldos descartan usuarios y secretos.

## Estructura

| Carpeta | Contenido |
|---|---|
| python/ | validar_cambio.py, generar_sucursal_02.py, auditar_flota.py, validar_inventario.py, medir_conectividad.py y comun.py (funciones compartidas) |
| datos/ | cambio_aprobado.yml, sucursal_02_entrada.yml, ipam_sucursal_01.json (y una variante con diferencias para pruebas) |
| evidencias/ | antes/ y despues/ (Ansible), salidas p1..p5 y mediciones_conectividad.csv |
| respaldos/ | evidencia de los equipos: running-config, version, vlan, troncales, interfaces y rutas |
| variables/ | diseño de la Sucursal 01 y sucursal_02_generada.yml |
| documentacion/ | este README y la configuración inicial manual |

## Orden de ejecución

    ansible-playbook playbooks/03_respaldos.yml -e destino=evidencias/antes
    # cambio aprobado con Ansible (02_switches.yml)
    ansible-playbook playbooks/03_respaldos.yml -e destino=evidencias/despues
    python3 python/validar_cambio.py
    python3 python/generar_sucursal_02.py
    ansible-playbook playbooks/03_respaldos.yml        # respaldos actuales
    python3 python/auditar_flota.py
    python3 python/validar_inventario.py
    python3 python/medir_conectividad.py

## Prototipo 1 - Validación antes y después de un cambio

- **Propósito:** demostrar que un cambio aprobado ocurrió y que lo crítico no se alteró.
- **Entradas:** evidencias/antes y evidencias/despues (Ansible), datos/cambio_aprobado.yml y variables/.
- **Qué evalúa:** que la descripción de GigabitEthernet0/2 del CORE pasó del valor anterior al nuevo
  sin tocar otras líneas de la interfaz; y que VLAN, troncales (configuración y estado), puertos de
  acceso, interfaz de gestión, subinterfaces del router, hostname y rutas son idénticos antes y después.
- **Salida:** evidencias/p1_salida.txt con CAMBIO APLICADO CORRECTAMENTE, ELEMENTO CRITICO SIN CAMBIOS
  o DIFERENCIA DETECTADA, e indica qué valor cambió. evidencias/p1_salida_con_diferencia.txt muestra el caso negativo.
- **Python y Ansible:** Ansible aplica el cambio y captura los estados; Python decide si el resultado es el esperado.

## Prototipo 2 - Datos para una nueva sede

- **Propósito:** calcular el direccionamiento de la Sucursal 02 y dejarlo como variables reutilizables.
- **Entradas:** datos/sucursal_02_entrada.yml (bloque 10.20.0.0/23; 50, 25 y 10 dispositivos).
- **Lógica:** a cada VLAN se le suman el gateway, la dirección de red y la de broadcast, y se elige el
  prefijo mínimo (/26, /27 y /28). Las subredes se asignan de mayor a menor, alineadas al bloque, y se
  verifica que no se solapen. El gateway es la primera dirección utilizable.
- **Salida:** variables/sucursal_02_generada.yml (VLAN, nombre, red, máscara, gateway, hosts previstos)
  y el resumen en evidencias/p2_salida.txt. No configura una sede real.
- **Python y Ansible:** Python calcula y organiza los datos; Ansible los consumirá después para configurar.

## Prototipo 3 - Auditoría de una flota pequeña

- **Propósito:** ampliar la auditoría inicial a R-SUC-01, SW-SUC-01-CORE y SW-SUC-01-ACC1.
- **Entradas:** variables/ y respaldos/<equipo>/ (running-config, show version, show vlan brief,
  show interfaces trunk, show ip interface brief).
- **Salida:** tabla en pantalla (evidencias/p3_salida.txt) y evidencias/p3_auditoria_flota.csv con equipo,
  condición, resultado, evidencia usada y detalle de la diferencia.
- **Python y Ansible:** Ansible recoge la evidencia de todos los equipos con el mismo playbook; Python la evalúa igual para todos.

## Prototipo 4 - Relación de fuentes de información

- **Propósito:** reproducir la integración entre IPAM, inventario y dispositivos.
- **Entradas:** datos/ipam_sucursal_01.json (simula la respuesta de una API), variables/*.yml,
  inventario/hosts.yml y los respaldos de Ansible.
- **Lógica:** compara nombre, red y gateway de cada VLAN; dirección de gestión, nombre y función de cada
  equipo. Cada elemento se clasifica como coincidencia, faltante (falta en alguna fuente) o diferencia
  (valores distintos), indicando la fuente de cada valor.
- **Salida:** evidencias/p4_salida_ok.txt (fuentes consistentes) y evidencias/p4_salida_con_diferencias.txt
  (con datos/ipam_sucursal_01_con_diferencias.json).
- **Python y Ansible:** Ansible aporta el estado real de los equipos; Python lo cruza con las fuentes declaradas.

## Prototipo 5 - Medición de conectividad de gestión

- **Propósito:** registrar y clasificar la calidad de la conexión de gestión.
- **Entradas:** direcciones ansible_host de inventario/hosts.yml.
- **Lógica:** diez pings ICMP desde el servidor a cada equipo; registra fecha, destino, enviados,
  recibidos, pérdida y latencia mínima, promedio y máxima. CUMPLE si no hay pérdida y el promedio es <= 50 ms.
- **Salida:** evidencias/mediciones_conectividad.csv (se agregan filas en cada ejecución) y evidencias/p5_salida.txt.
- **Python y Ansible:** la medición se hace desde el servidor de automatización; Ansible sigue siendo la vía
  para consultar y configurar los equipos.

## Conclusión técnica

Ansible y Python se complementan. Ansible actúa sobre los equipos de forma repetible: configura, guarda,
respalda y captura estados (antes/después, show version, troncales, rutas) con el mismo playbook en cualquier
equipo. Python convierte esa evidencia en decisiones: valida cambios, calcula direccionamiento, audita,
cruza fuentes y mide.

Para una organización con muchas sedes aporta más valor **Ansible**, porque es la base: sin cambios
repetibles y evidencia homogénea no hay datos confiables que analizar, y cada sede adicional se despliega
con las mismas variables. Python multiplica ese valor (auditoría continua, planificación de nuevas sedes,
integración con IPAM) pero depende de lo que Ansible entrega. La mayor ganancia viene de usarlos juntos:
Ansible ejecuta y recolecta, Python verifica y planifica.
__FIN__

grep -q '## Prototipos de Python aplicados a redes' README.md || cat >> README.md << '__FIN__'

## Prototipos de Python aplicados a redes

Cinco prototipos en `python/` (validar cambios, generar datos de una nueva sede, auditar la flota,
relacionar fuentes y medir conectividad). Propósito, entradas, salidas y conclusión en
[documentacion/README.md](documentacion/README.md). Todos leen evidencias guardadas por Ansible y
ninguno configura equipos ni abre SSH.
__FIN__

chmod +x python/*.py
python3 -m py_compile python/*.py
echo
echo "Listo. Archivos creados en python/, datos/, documentacion/ y playbooks/03_respaldos.yml actualizado."
