5.1 R-SUC-01
enable
configure terminal
hostname R-SUC-01
no ip domain-lookup
ip domain-name sucursal01.local
username admin privilege 15 secret Suc01Lab2026
crypto key generate rsa modulus 2048
ip ssh version 2
line vty 0 4
 login local
 transport input ssh
 exec-timeout 0 0
 exit
line con 0
 logging synchronous
 exit
interface GigabitEthernet0/2
 description ENLACE DE AUTOMATIZACION HACIA UBUNTU SERVER
 ip address 192.168.100.1 255.255.255.0
 no shutdown
 exit
end
write memory

5.2 SW-SUC-01-CORE
enable
configure terminal
hostname SW-SUC-01-CORE
no ip domain-lookup
ip domain-name sucursal01.local
username admin privilege 15 secret Suc01Lab2026
crypto key generate rsa modulus 2048
ip ssh version 2
line vty 0 4
 login local
 transport input ssh
 exec-timeout 0 0
 exit
line con 0
 logging synchronous
 exit
vlan 99
 name GESTION
 exit
interface GigabitEthernet0/0
 switchport trunk encapsulation dot1q
 switchport mode trunk
 switchport trunk native vlan 99
 switchport trunk allowed vlan 10,20,99
 exit
interface GigabitEthernet1/2
 switchport trunk encapsulation dot1q
 switchport mode trunk
 switchport trunk native vlan 99
 switchport trunk allowed vlan 10,20,99
 exit
interface Vlan99
 ip address 192.168.99.2 255.255.255.0
 no shutdown
 exit
ip route 0.0.0.0 0.0.0.0 192.168.99.1
end
write memory

5.3 SW-SUC-01-ACC1
enable
configure terminal
hostname SW-SUC-01-ACC1
no ip domain-lookup
ip domain-name sucursal01.local
username admin privilege 15 secret Suc01Lab2026
crypto key generate rsa modulus 2048
ip ssh version 2
line vty 0 4
 login local
 transport input ssh
 exec-timeout 0 0
 exit
line con 0
 logging synchronous
 exit
vlan 99
 name GESTION
 exit
interface GigabitEthernet0/0
 switchport trunk encapsulation dot1q
 switchport mode trunk
 switchport trunk native vlan 99
 switchport trunk allowed vlan 10,20,99
 exit
interface Vlan99
 ip address 192.168.99.3 255.255.255.0
 no shutdown
 exit
ip route 0.0.0.0 0.0.0.0 19ss2.168.99.1
end
write memory
