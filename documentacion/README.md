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
