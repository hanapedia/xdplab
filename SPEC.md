## Topology

### Ports
front port = Port further away from the motherboard
back port  = Port closer to the motherboard

r5500:
- enp1s0f0 (front port) managed by host
    - 10.10.0.1
    - a0:36:9f:40:77:c0
- enp1s0f1 (back port) managed by host
    - 10.10.1.1
    - a0:36:9f:40:77:c2

r9600:
- enp4s0f0 (front port) unmanaged by NetworkManager
    - 10.10.0.2
    - a0:36:9f:f9:b1:b4
- enp4s0f1 (back port) unmanaged by NetworkManager
    - 10.10.1.2
    - a0:36:9f:f9:b1:b5

### Links
r5500[enp1s0f0] - r9600[enp4s0f0] (10.10.0.0/30)
r5500[enp1s0f1] - r9600[enp4s0f1] (10.10.1.0/30)

### LAN
r5500: 192.168.1.200 (enp7s0)
r9600: 192.168.1.100 (enp9s0)

## BGP

r5500: AS 64513
r9600: AS 64512
