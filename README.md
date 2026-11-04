# Automatización y auditoría de la Sucursal 01

Configuración de R-SUC-01, SW-SUC-01-CORE y SW-SUC-01-ACC1 con Ansible y
auditoría de cumplimiento con Python.

## Función de cada herramienta

- **Ansible** aplica y respalda la configuración: crea las VLAN 10, 20 y 99,
  configura troncales (nativa 99, permitidas 10,20,99), puertos de acceso,
  descripciones, direcciones de gestión y subinterfaces del router; guarda los
  cambios y deja en `respaldos/` la running-config y el `show vlan brief`.
  Es idempotente: una segunda ejecución no cambia nada.
- **Python** audita la evidencia: lee el diseño desde `variables/*.yml` y los
  respaldos de Ansible, y reporta CUMPLE o NO CUMPLE por VLAN, troncal y puerto
  de acceso, indicando qué condición no coincide. No abre SSH ni configura equipos.

## Estructura

- inventario/: hosts y credenciales (cifradas con Ansible Vault)
- variables/: diseño declarado (VLAN, puertos, enlaces, descripciones)
- playbooks/: 01_router, 02_switches, 03_respaldos, 04_conectividad, site
- respaldos/: evidencia generada por Ansible
- auditoria/auditar.py: programa de auditoría
- evidencias/: salidas de las ejecuciones y capturas

## Requisitos

Ubuntu Server con Python 3, Ansible, PyYAML y paramiko 3.5.1 en un entorno
virtual, y la colección cisco.ios. Los equipos deben tener SSH habilitado y el
usuario admin (configuración inicial manual descrita en documentacion/).

## Uso

    source .venv/bin/activate
    ansible-playbook playbooks/site.yml          # configurar, guardar y respaldar
    ansible-playbook playbooks/site.yml          # segunda ejecución: changed=0
    ansible-playbook playbooks/04_conectividad.yml
    python3 auditoria/auditar.py                 # auditoría

El vault usa `.vault_pass`, que no se sube al repositorio. Para reproducir el
proyecto, crea ese archivo y vuelve a cifrar inventario/group_vars/all/vault.yml
con la variable vault_password_dispositivos.

## Notas de implementación

- **paramiko 3.5.1:** las versiones nuevas no ofrecen los intercambios de claves
  SHA-1 que usa IOSv y Ansible falla con "no acceptable kex algorithm".
- **Ruta por defecto en los switches:** IOSv L2 no usa ip default-gateway;
  el playbook configura ip route 0.0.0.0 0.0.0.0 192.168.99.1 para que el
  switch responda a otras subredes (por ejemplo, al Ubuntu).
- **VLAN con ios_vlans:** en un switch con VTP servidor las VLAN no salen en la
  running-config; ios_vlans las compara con show vlan y la segunda ejecución
  queda en changed=0.
- **Red del servidor:** el Ubuntu de escritorio usa NetworkManager; el enlace
  de automatización (192.168.100.10/24) se configura con nmcli, sin netplan.
- **Enlace con GNS3:** Cloud1 usa la tarjeta eth1 de la VM de GNS3, que debe
  tener el modo promiscuo activo (se pierde al reiniciar; se deja con cron).

## Notas

Switch1 (conecta PC8) es un equipo de capa 2 fuera del alcance: no está en el
inventario ni se configura. La red 192.168.100.0/24 es el enlace de
automatización entre el Ubuntu Server y R-SUC-01 (Gi0/2).


## Prototipos de Python aplicados a redes

Cinco prototipos en `python/` (validar cambios, generar datos de una nueva sede, auditar la flota,
relacionar fuentes y medir conectividad). Propósito, entradas, salidas y conclusión en
[documentacion/README.md](documentacion/README.md). Todos leen evidencias guardadas por Ansible y
ninguno configura equipos ni abre SSH.
