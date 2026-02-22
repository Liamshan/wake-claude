# Jarvis Raspberry Pi - Configuration & Reference

> **Purpose of this directory:** General-purpose use and debugging of the Jarvis Pi and its accompanying utilities. This document is a key reference for any future agent working in this context.

---

## 1. Device Overview

- **Device name:** Jarvis
- **Device type:** Raspberry Pi 5 (aarch64)
- **OS:** Debian GNU/Linux (Raspberry Pi OS Bookworm-based)
- **Kernel (as of last check):** `6.12.47+rpt-rpi-2712`
- **Username:** `pi`
- **Purpose:** Multi-service home server (Pi-hole, YOLO dog detector, weather alerts, n8n workflows, webcam streamer via NordVPN MeshNet)

---

## 2. Network Configuration

- **Local WiFi network name:** Alabama
- **Router:** Eero (landlord-controlled, no admin access)
- **Router gateway IP:** 192.168.4.1
- **Subnet mask:** 255.255.252.0 (/22)
- **Jarvis LAN IP (static):** 192.168.7.15
- **Jarvis NordVPN MeshNet IP:** 100.72.153.252

### Static IP Configuration

The static IP is set via **NetworkManager** (not dhcpcd). The connection is named `"preconfigured"`. The current static config was applied with:

```bash
sudo nmcli connection modify preconfigured \
  ipv4.method manual \
  ipv4.addresses 192.168.7.15/22 \
  ipv4.gateway 192.168.4.1 \
  ipv4.dns "127.0.0.1 1.1.1.1"

sudo nmcli connection up preconfigured
```

To verify the static IP is set correctly:

```bash
ip addr show wlan0
```

Expected output should show `inet 192.168.7.15/22` with `valid_lft forever` (not `dynamic`).

---

## 3. Remote Access

### SSH

| Method | Command | When to use |
|---|---|---|
| **MeshNet (preferred)** | `ssh pi@100.72.153.252` | Works from anywhere, most reliable |
| **LAN** | `ssh pi@192.168.7.15` | Only when on the "Alabama" WiFi network |

> **Note:** `ssh pi@Jarvis.local` (mDNS) is unreliable from WSL2 due to known mDNS resolution issues.

### NordVPN MeshNet

MeshNet provides remote access to Jarvis from anywhere via a WireGuard tunnel (`nordlynx` interface). The MeshNet IP (`100.72.153.252`) is separate from the LAN IP and may differ. MeshNet must be active on both the Pi and the connecting device.

To check MeshNet status on the Pi:

```bash
nmcli device status   # Should show nordlynx as connected
```

---

## 4. Services

### Pi-hole (Network-Wide Ad Blocking)

- **Runs in:** Docker (host network mode)
- **Container name:** `pihole`
- **Docker image:** `pihole/pihole:latest`
- **Admin interface (LAN):** http://192.168.7.15/admin
- **Admin interface (MeshNet):** http://100.72.153.252/admin
- **DNS address for client devices:** 192.168.7.15
- **Backup DNS:** 1.1.1.1

Docker volumes:
```
./etc-pihole:/etc/pihole
./etc-dnsmasq.d:/etc/dnsmasq.d
```

Common commands:
```bash
docker ps                  # Check if Pi-hole is running
docker start pihole        # Start Pi-hole if stopped
docker restart pihole      # Restart Pi-hole
docker logs pihole         # View Pi-hole logs
```

### Webcam Streamer

- **Accessible at:** http://100.72.153.252:8081 (via MeshNet)
- **Purpose:** Home webcam, integrated with YOLO dog detection (planned)

### Planned/Future Services

- YOLOv8/YOLO-NAS dog presence detection via attached webcam
- Weather alert automation (thunderstorm warnings)
- n8n workflow integration (notifications, triggers, automations)
- Possibly: Grafana, Node-RED, Home Assistant, custom APIs

---

## 5. Client Device DNS Configuration

Since the Eero router is landlord-controlled, DNS must be set **device-by-device**.

### Android Device

- **IP address:** 192.168.7.x (assigned via WiFi)
- **Gateway:** 192.168.4.1
- **Prefix length:** 22
- **DNS1:** 192.168.7.15 (Pi-hole)
- **DNS2:** 1.1.1.1

### Fire TV Stick

- **IP:** 192.168.7.9
- **Gateway:** 192.168.4.1
- **Netmask:** 255.255.252.0
- **DNS1:** 192.168.7.15
- **DNS2:** 1.1.1.1
- **Setup steps:** Forget network > Reconnect with "Advanced" > Manually enter values

---

## 6. Troubleshooting

### Can't reach Jarvis at 192.168.7.15

1. **Are you on the "Alabama" network?** The LAN IP only works locally.
2. **Try the MeshNet IP instead:** `ssh pi@100.72.153.252`
3. **The IP may have drifted.** If the static config was lost (e.g., after an OS update), the Pi may have gotten a new DHCP address. SSH in via MeshNet and check:
   ```bash
   ip addr show wlan0
   ```
   If you see `dynamic` and a different IP, re-apply the static IP config from Section 2.

### Pi-hole not blocking ads

1. SSH into Jarvis and check if the container is running: `docker ps`
2. If not running: `docker start pihole`
3. Verify client devices still have DNS set to 192.168.7.15

### SSH says "could not resolve hostname"

- Don't use `Jarvis.local` from WSL2 — mDNS doesn't work reliably there.
- Use the IP address directly (LAN or MeshNet).

### General diagnostics

```bash
uptime                     # How long the Pi has been running
docker ps                  # List running containers
ip addr show wlan0         # Check LAN IP and static vs dynamic
nmcli device status        # Check all network interfaces
nmcli connection show preconfigured  # Full network config details
```

---

## 7. Important Notes

- **Eero admin access is not available** (landlord-controlled). All DNS routing must be set device-by-device.
- **Jarvis should remain on a stable power supply** to avoid unexpected shutdowns.
- **MeshNet IP may differ from LAN IP** — always check both when troubleshooting connectivity.
- The Pi has demonstrated long uptimes (63+ days observed) and is generally very stable.
