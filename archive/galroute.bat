rem Adjusts routes when connected to Galazar VPN

route delete 0.0.0.0
route add 0.0.0.0 mask 0.0.0.0 192.168.2.1

route add 192.168.1.0 mask 255.255.255.0 192.168.1.%1

