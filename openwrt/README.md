# EzWrt Dedicated OpenWrt Firmware

This directory builds a reproducible x86/64 firmware from the official OpenWrt
25.12.6 SDK and ImageBuilder. It does not inherit Kwrt's rolling package feeds,
fullcone patches, or custom miniupnp packages.

## Included behavior

- PassWall Plus with nftables, OpenVPN, Xray, and Sing-box support.
- `luci-app-passwall-ezcnet` cloud agent and LuCI settings, disabled by default
  with no embedded device Key; the default HTTPS endpoint is passwall.ezcnet.com.
- Global and per-device OpenVPN, including Xray/Sing-box pre-proxy nodes.
- A Plus overview centered on device exits, IP/MAC binding, VPN tunnels and switch protection.
- Local .ovpn import with profile checks, lease-based device selection and disabled policy drafts.
- DHCP static lease and IP/MAC binding support from PassWall Plus.
- Network protection during node switches, including failed startup and core updates.
- Kernel MPTCP disabled as a mitigation for the IPv4 MPTCP listener vulnerability.
- EzWrt LuCI theme and hostname, with a forest-green sidebar, teal accents,
  responsive navigation and automatic light/dark appearance. Bootstrap remains
  available as a fallback in System → System → Language and Style.
- `eth0` as DHCP WAN; `eth1` and all other detected `ethN` ports as bridged LAN
  at `10.0.0.1/24`. Disconnected ports are included; VLAN devices are excluded.
- IPv6 disabled in sysctl and network services, plus an explicit LAN reject rule.
- VMware e1000/e1000e/vmxnet3 drivers and the official x86 kernel's virtio support.
- BIOS and UEFI, ext4 and squashfs combined images with a 1 GiB root partition.
- VMware stream-optimized VMDK copies of both ext4 images.

No subscription, OpenVPN profile, private key, or preset root password is added.
The first boot follows OpenWrt's official empty-password behavior. Set a strong
root password immediately after logging in.

## Build

On Debian or Ubuntu, install the normal OpenWrt SDK dependencies plus `zstd`,
`qemu-utils`, `gawk`, and `libncurses-dev`, then run:

```sh
./openwrt/scripts/build-firmware.sh
```

The output is written to `dist/openwrt/25.12.6/`. Downloads and extracted build
trees are cached under `.cache/openwrt/25.12.6/`. Override these locations with
`PASSWALL_BUILD_CACHE` and `FIRMWARE_OUTPUT_DIR` when needed.

All upstream archives are checked against the SHA-256 values in `versions.env`.
The official SDK already pins every OpenWrt feed to the 25.12.6 release commit;
the PassWall package feed is pinned separately. The local PassWall Plus checkout
is linked into the SDK so the firmware always contains the source being built.
Only the Go build tooling is backported from a separately pinned OpenWrt packages
commit, with Go 1.27.3 selected for Xray 26.10.31. Target package feeds and the firmware
kernel remain on the 25.12.6 baseline. Both pins are recorded in `build-info.txt`.

## Test

The test boots the BIOS ext4 image with four emulated e1000 NICs and checks the
network mapping (including automatic eth2/eth3 bridge membership), WAN DHCP,
IPv6 policy, installed binaries, EzWrt templates and static assets, LuCI, `fw4 check`,
`fw4 reload`, and kernel logs for nftables crashes:

```sh
./openwrt/scripts/test-qemu.sh
```

The test uses TCP port 2222 by default. Set `QEMU_SSH_PORT` if that port is in
use. The QEMU disk is a temporary copy, so the firmware artifact is not modified.
It also compiles the installed Lua sources, renders authenticated LuCI global,
Plus overview, OpenVPN-node and device policy pages, checks the read-only status API and POST-only draft endpoint, verifies global OpenVPN supervision and fail-closed
routing with an unreachable test server, and checks managed DHCP leases and
IP/MAC guard creation and cleanup. A second isolated VM establishes a real TLS
OpenVPN tunnel, verifies HTTPS through its TUN device, and checks that the Plus status API distinguishes global, simultaneous and device-only tunnels. A third emulated NIC injects real LAN TCP,
UDP, DNS and ICMP packets and verifies that no matching packets reach the WAN
while the switch guard is active, including an established offloaded UDP flow,
fw4 reload and partial protection failures. Local SOCKS/TLS fixtures exercise
verified startup, unreachable-node rollback, delayed listeners, controller death,
new-request cancellation, failed binary replacement, orphan cleanup, runtime
core death and recovery after an unavailable upstream returns.
Installed-parser tests cover subscription URI passwords, explicit/default ports,
IPv6 hosts, Naive scheme names, and the cloud converter's read-only/error contract.
An independent LAN client also requests new unicast/broadcast DHCP leases,
renews an existing lease, and loads LuCI by LAN IP during protection, an
unreachable-node health check, sustained recovery, and verified restoration.
Its test link filters QEMU's built-in DHCP replies so they cannot mask a router
DHCP failure. The test temporarily forces dnsmasq DHCP on the emulated LAN.
`QEMU_PROBE_PORT` (default 2233, also reserving the following UDP port) can be
changed for concurrent runs. No host root privileges or external proxy account
are needed. The OpenVPN fixture also reserves TCP `QEMU_SSH_PORT + 10` and
UDP `QEMU_SSH_PORT + 20`; it requires the host `openssl` command.
The DHCP/management client reserves TCP `QEMU_SSH_PORT + 30` and `+ 31`.

The Plus self-updater's version selection and rejection of upstream package URLs
can be tested separately with Python 3 and Lua 5.1:

```sh
python3 openwrt/tests/test-updater.py
python3 openwrt/tests/test-switch-lifecycle.py
```

## GitHub releases

The workflow always stores a 14-day GitHub Actions artifact. A tag matching
`firmware-v*` also creates a permanent GitHub Release after the firmware passes
the QEMU boot test, and uploads all images, manifests, build metadata, and
`SHA256SUMS`. For example:

```sh
git tag -a firmware-v25.12.6-r3 -m "PassWall Plus OpenWrt 25.12.6 r3"
git push origin firmware-v25.12.6-r3
```

The release also includes the built `luci-app-passwall`, `luci-app-passwall-ezcnet`,
`luci-theme-ezwrt`, and Simplified Chinese translation APKs. The LuCI self-updater reads this repository's release assets and
compares the package version, independently of the OpenWrt firmware tag. These
APKs target the dedicated 25.12 firmware; older opkg releases need their own SDK
builds.

EzCNet is included by default starting with firmware `25.12.5-r5`. When adding it
to an older image, install both PassWall Plus `26.10.22-r4` and EzCNet `0.2.0-r1`;
the agent requires the Plus parser interface introduced in this release.

## VMware installation

Use the `generic-ext4-combined.vmdk` image for legacy BIOS or
`generic-ext4-combined-efi.vmdk` for UEFI. Attach two NICs in this order:

1. WAN (`eth0`): any IPv4 uplink that provides DHCP, such as VMware NAT, a
   bridged network, or an Ethernet network with an upstream DHCP router.
2. LAN (`eth1`): host-only/custom network connected to the test client.
3. Optional additional NICs (`eth2`, `eth3`, …): automatically bridged into LAN.

This order differs from historical 25.12.6-r3 images. Reconnect the adapters
when installing a new EzWrt build. The firmware requires at least two NICs.

The WAN setup is not VMware-specific: `eth0` is a normal DHCP client and uses
the IPv4 address, default gateway, and DNS supplied by the upstream network.

After boot, open `http://10.0.0.1/`, set the root password, then import
proxy subscriptions and OpenVPN profiles through LuCI. Secrets must remain in
the router configuration and must not be committed to this repository.
