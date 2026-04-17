# Architecture

## Overview

3-node Pi 5 k3s cluster with diskless PXE boot. Nodes have no SD cards — they boot entirely over the network from a dedicated PXE server Pi.

```
┌─────────────────────────────────────────────────────────────────┐
│  Router (192.168.1.1) — DHCP server for the LAN                 │
└──────────────────────┬──────────────────────────────────────────┘
                       │
┌──────────────────────▼──────────────────────────────────────────┐
│  Pi PXE Server (192.168.1.75, Tailscale: pi-pxe)               │
│                                                                  │
│  dnsmasq  — proxy DHCP mode: intercepts PXE requests,           │
│             sends TFTP server address (no IP assignment)         │
│                                                                  │
│  tftpd-hpa — serves /tftpboot/<serial>/                         │
│    ├── start4.elf, fixup.dat, dtb files  (Pi 5 firmware)        │
│    └── cmdline.txt  (per-node: nfsroot=...)                      │
│                                                                  │
│  nfs-server — exports:                                           │
│    /tftpboot/images/pi5-1  → pi-1 root filesystem               │
│    /tftpboot/images/pi5-2  → pi-2 root filesystem               │
│    /tftpboot/images/pi5-3  → pi-3 root filesystem               │
│                                                                  │
│  systemd .mount units:                                           │
│    /tftpboot/firmware/pi-N  bind→ /tftpboot/images/pi5-N/       │
│                                   boot/firmware/                 │
│    (provides per-node user-data/meta-data to cloud-init)        │
└──────────────────────────────────────────────────────────────────┘
         │ TFTP                    │ NFS
         ▼                         ▼
┌────────────────┐  ┌────────────────┐  ┌────────────────┐
│  pi-1          │  │  pi-2          │  │  pi-3          │
│  192.168.1.149 │  │  192.168.1.207 │  │  192.168.1.29  │
│  k3s server    │  │  k3s agent     │  │  k3s agent     │
│  NVMe: 477G    │  │  NVMe: 466G    │  │  NVMe: 477G    │
└────────────────┘  └────────────────┘  └────────────────┘
```

## Node Identity

| Node  | MAC               | Short Serial | Tailscale IP    |
|-------|-------------------|--------------|-----------------|
| pi-1  | 2c:cf:67:08:6f:e8 | c5013a79     | 100.119.198.110 |
| pi-2  | 2c:cf:67:19:6c:ff | fc1e11b7     | 100.92.105.38   |
| pi-3  | 2c:cf:67:19:6d:d1 | 6b91f29e     | 100.78.103.10   |
| pi-pxe| —                 | SD card      | 100.85.130.34   |

## Boot Sequence

1. Pi powers on, EEPROM checks boot order `0xf21` (SD → Network → stop)
2. No SD card present → tries network
3. Pi broadcasts DHCP request
4. Router assigns IP; dnsmasq (proxy DHCP) sends PXE offer with TFTP server IP
5. Pi downloads firmware from `tftp://192.168.1.75/<short-serial>/`
6. Pi reads `cmdline.txt` → mounts NFS root at `192.168.1.75:/tftpboot/images/pi5-N`
7. Linux boots from NFS root
8. cloud-init reads `user-data` from `/boot/firmware/` (bind-mounted from `/tftpboot/firmware/pi-N/`)
9. cloud-init partitions NVMe, installs Tailscale, installs k3s

## NVMe Layout (all nodes)

| Partition | Size  | Type | Label       | Purpose                      |
|-----------|-------|------|-------------|------------------------------|
| p1        | 512M  | vfat | system-boot | Unused (diskless boot)       |
| p2        | 63.5G | ext4 | writable    | `/var/lib/rancher` (k3s data)|
| p3        | rest  | LVM2 | —           | Longhorn block storage       |

k3s data (containerd images, etcd, kubelet) lives on NVMe p2 mounted at `/var/lib/rancher`. Longhorn uses p3 via LVM as raw block storage.

## EEPROM

All nodes require `BOOT_ORDER=0xf21` (SD → Network → stop). The custom recovery image `custom-eeprom-0xf21-v2.img` sets this. Standard recovery images set `0xf21` only on Pi 5 `2712` variant — never use `2711` (Pi 4) images.

## Secrets

| Secret            | Where used              | Storage          |
|-------------------|-------------------------|------------------|
| TAILSCALE_AUTH_KEY| All cloud-init runcmd   | `.env` (gitignored)|
| K3S_TOKEN         | k3s server + agents     | `.env` (gitignored)|

The Makefile substitutes these into cloud-init at image build time. The `setup-nfs-roots.sh` script also substitutes them into per-node user-data at PXE server first-boot time. Neither is ever committed.
