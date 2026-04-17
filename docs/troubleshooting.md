# Troubleshooting

Hard-won lessons from building this cluster. Read this before debugging.

---

## EEPROM / Boot Order

### Pi won't PXE boot — no DHCP request seen

**Cause**: Default Pi 5 EEPROM boot order (`0xf1`) only tries SD card. Network boot is not attempted unless BOOT_ORDER includes `2` (network).

**Fix**: Flash EEPROM recovery image to SD card to set `BOOT_ORDER=0xf21` (SD → Network → stop).

```bash
pi-eeprom-recovery --flash-only ~/Downloads/pi-eeprom/custom-eeprom-0xf21-v2.img
```

Physical procedure:
1. Insert flashed SD into Pi
2. Power on — green LED blinks recovery pattern
3. Wait ~15s — **Pi does NOT auto-power-off** with the custom image; cut power manually after pattern stabilises
4. Remove SD, power on — Pi now tries network

**Wrong image variant**: Must use `2712` variant for Pi 5, not `2711` (Pi 4). Wrong variant silently does nothing.

---

### Pi still boots SD after EEPROM update

BOOT_ORDER=0xf21 means SD is tried first. If an SD card is physically present, it boots from it — even after EEPROM update. Remove the SD card.

---

## PXE Boot

### No TFTP activity after DHCP

Check dnsmasq is running and the Pi's serial TFTP dir exists:

```bash
ssh pxe "sudo journalctl -u dnsmasq -f"
ssh pxe "ls /tftpboot/<short-serial>/"
```

Short serial = last 8 hex chars of full serial. Get full serial from:

```bash
# On a booted Pi:
cat /sys/firmware/devicetree/base/serial-number | xxd -p | tail -c 17 | head -c 16
```

Or from dnsmasq logs: the `client-machine-id` field contains the serial in bytes 5-12.

---

### Pi gets DHCP, starts TFTP, then hangs

Usually an NFS mount failure. Check:

```bash
ssh pxe "sudo journalctl -u nfs-server --no-pager | tail -20"
ssh pxe "exportfs -v"
ssh pxe "mount | grep tftpboot"  # bind mounts must be active
```

Bind mounts don't survive PXE server reboots unless the systemd .mount units are enabled. Verify:

```bash
ssh pxe "systemctl status 'tftpboot-images-pi5\x2d1-boot-firmware.mount'"
```

---

### SSH not available after Pi OS boots

Pi OS requires an empty `/boot/firmware/ssh` file to enable the SSH service at first boot. cloud-init alone is not sufficient.

In the NFS root's firmware dir:
```bash
ssh pxe "touch /tftpboot/firmware/pi-N/ssh"
```

---

## cloud-init

### cloud-init falls back to DataSourceNone

Means `user-data` and `meta-data` are missing from `/boot/firmware/` in the NFS root. The bind mount must be active and the firmware dir must contain both files.

```bash
ssh pxe "ls /tftpboot/firmware/pi-N/"
# Must show: user-data  meta-data  ssh
ssh pxe "systemctl is-active 'tftpboot-images-pi5\x2dN-boot-firmware.mount'"
```

---

### cloud-init: `run.mount` bad unit file setting

A stale `run.mount` unit in `/etc/systemd/system/` of the NFS root causes systemd to refuse it (it cannot mount API filesystems like `/run` via unit files). This cascades to block any service that depends on `run.mount`, including `tailscaled`.

**Fix**: Remove from the NFS root:

```bash
ssh pxe "sudo rm /tftpboot/images/pi5-N/etc/systemd/system/run.mount"
ssh pxe "sudo rm /tftpboot/images/pi5-N/etc/systemd/system/local-fs.target.wants/run.mount"
```

Then on the node: `sudo systemctl daemon-reload && sudo systemctl start tailscaled`.

---

### cloud-init re-runs not working

cloud-init caches completion. To force a re-run after updating user-data:

```bash
# On the node:
sudo cloud-init clean --logs
sudo reboot
```

For NFS-booted nodes: update the file in `/tftpboot/firmware/pi-N/user-data` (visible to the node at `/boot/firmware/user-data`), then run `cloud-init clean` and reboot.

---

## Physical / Hardware

### Physical Pi labeling vs switch port confusion

If Pis are on the wrong switch ports, their MAC addresses will resolve to the wrong TFTP serial directories. Verify each Pi's serial:

```bash
ssh piN "cat /sys/firmware/devicetree/base/serial-number | xxd -p | tail -c 17 | head -c 16"
```

Cross-reference with the node inventory in `~/.claude/skills/pi-cluster.md`.

---

### `sudo` warns "unable to resolve host"

Occurs when the running hostname doesn't match `/etc/hosts`. Not fatal — sudo still works. Fix:

```bash
# On the Pi:
echo "127.0.1.1  $(hostname)" | sudo tee -a /etc/hosts
```

---

## Tailscale

### `tailscaled` fails to start on NFS-booted Pi

Most commonly caused by the `run.mount` unit issue above. Check `systemctl status tailscaled` and `systemctl status run.mount`.

---

## NVMe

### `sgdisk` not found

Pi OS Lite doesn't include `gdisk`. Use `parted` instead — it's available or installable via apt. See the `runcmd` in node user-data files for the correct parted invocation.

### `pvcreate` not found

lvm2 is not installed by default on Pi OS. Add `lvm2` to the `packages` list in cloud-init, or install manually: `sudo apt-get install -y lvm2`.

---

## PXE Server Rebuild

If the PXE server SD card fails or you need to rebuild from scratch:

1. `make pxe-image` (requires `.env` with secrets)
2. `make flash DEVICE=/dev/diskN`
3. Insert SD into PXE server Pi, power on
4. Wait ~15 min for `setup-nfs-roots.sh` to complete (check `/var/log/setup-nfs-roots.log`)
5. Power on nodes — they will PXE boot and cloud-init runs automatically

Node cloud-init takes ~5 min per node. k3s agents wait for the server, which may take an additional 1-2 min to start.
