## Driver config
0. Find the PCI slots
```sh
lspci | grep ethernet
```

1. Show device ID
```sh
lspci -n -s 04:00.0
lspci -n -s 04:00.1
```

2. Enable vfio-pci module 
```sh
sudo modprobe vfio-pci
```

3. Unbind from current driver. This removes the file.
*Driver actions are performedy by writing args to a path for each action*
```sh
echo 0000:04:00.0 | sudo tee /sys/bus/pci/devices/0000:04:00.0/driver/unbind
echo 0000:04:00.1 | sudo tee /sys/bus/pci/devices/0000:04:00.1/driver/unbind
```

4. Write driver override to use vfio-pci instead.
```sh
echo vfio-pci | sudo tee /sys/bus/pci/devices/0000:04:00.0/driver_override
echo vfio-pci | sudo tee /sys/bus/pci/devices/0000:04:00.1/driver_override
```

5. Trigger re-probe of the driver fo the devices.
```sh
echo 0000:04:00.0 | sudo tee /sys/bus/pci/drivers_probe
echo 0000:04:00.1 | sudo tee /sys/bus/pci/drivers_probe
```

6. Confirm
```sh
lspci -k -s 04:00.0
lspci -k -s 04:00.1
```

## Persistence
1. Write a simple script for unbind, override, and probe
```sh
sudo tee /usr/local/sbin/vfio-bind-x550.sh > /dev/null << 'EOF'
#!/bin/sh
set -e

modprobe vfio-pci

for dev in 0000:04:00.0 0000:04:00.1; do
  if [ -e "/sys/bus/pci/devices/$dev/driver" ]; then
    echo "$dev" > "/sys/bus/pci/devices/$dev/driver/unbind"
  fi
  echo vfio-pci > "/sys/bus/pci/devices/$dev/driver_override"
  echo "$dev" > /sys/bus/pci/drivers_probe
done
EOF
sudo chmod +x /usr/local/sbin/vfio-bind-x550.sh
```

2. Create systemd oneshot service
```sh
sudo tee /etc/systemd/system/vfio-bind-x550.service > /dev/null << 'EOF'
[Unit]
Description=Bind X550 ports to vfio-pci
After=systemd-udev-settle.service
Before=libvirtd.service
StartLimitIntervalSec=60
StartLimitBurst=20

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/vfio-bind-x550.sh
RemainAfterExit=yes
Restart=on-failure
RestartSec=1

[Install]
WantedBy=multi-user.target
EOF
```

3. Enable the service
```sh
sudo systemctl daemon-reload
sudo systemctl enable --now vfio-bind-x550.service
```

4. Verify
```sh
lspci -k -s 04:00.0
lspci -k -s 04:00.1 
sudo reboot
systemctl status vfio-bind-x550.service
lspci -k -s 04:00.0
lspci -k -s 04:00.1
```
