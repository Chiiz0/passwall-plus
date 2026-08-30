# PassWall Plus Dedicated OpenWrt Firmware

This directory builds a reproducible x86/64 firmware from the official OpenWrt
25.12.5 SDK and ImageBuilder. It does not inherit Kwrt's rolling package feeds,
fullcone patches, or custom miniupnp packages.

## Included behavior

- PassWall Plus with nftables, OpenVPN, Xray, and Sing-box support.
- Global and per-device OpenVPN, including Xray/Sing-box pre-proxy nodes.
- DHCP static lease and IP/MAC binding support from PassWall Plus.
- `eth0` as LAN at `10.0.0.1/24`; `eth1` as DHCP WAN.
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

The output is written to `dist/openwrt/25.12.5/`. Downloads and extracted build
trees are cached under `.cache/openwrt/25.12.5/`. Override these locations with
`PASSWALL_BUILD_CACHE` and `FIRMWARE_OUTPUT_DIR` when needed.

All upstream archives are checked against the SHA-256 values in `versions.env`.
The official SDK already pins every OpenWrt feed to the 25.12.5 release commit;
the PassWall package feed is pinned separately. The local PassWall Plus checkout
is linked into the SDK so the firmware always contains the source being built.

## Test

The test boots the BIOS ext4 image with two emulated e1000 NICs and checks the
network mapping, WAN DHCP, IPv6 policy, installed binaries, LuCI, `fw4 check`,
`fw4 reload`, and kernel logs for nftables crashes:

```sh
./openwrt/scripts/test-qemu.sh
```

The test uses TCP port 2222 by default. Set `QEMU_SSH_PORT` if that port is in
use. The QEMU disk is a temporary copy, so the firmware artifact is not modified.
The currently generated 25.12.5 image passes this test without the
`libnftables` segfault observed on the Kwrt snapshot.

## GitHub releases

The workflow always stores a 14-day GitHub Actions artifact. A tag matching
`firmware-v*` also creates a permanent GitHub Release after the firmware passes
the QEMU boot test, and uploads all images, manifests, build metadata, and
`SHA256SUMS`. For example:

```sh
git tag -a firmware-v25.12.5-r1 -m "PassWall Plus OpenWrt 25.12.5 r1"
git push origin firmware-v25.12.5-r1
```

## VMware installation

Use the `generic-ext4-combined.vmdk` image for legacy BIOS or
`generic-ext4-combined-efi.vmdk` for UEFI. Attach two NICs in this order:

1. LAN: host-only/custom network connected to the test client.
2. WAN: any IPv4 uplink that provides DHCP, such as VMware NAT, a bridged
   network, or an Ethernet network with an upstream DHCP router.

The WAN setup is not VMware-specific: `eth1` is a normal DHCP client and uses
the IPv4 address, default gateway, and DNS supplied by the upstream network.

After boot, open `http://10.0.0.1/`, set the root password, then import
proxy subscriptions and OpenVPN profiles through LuCI. Secrets must remain in
the router configuration and must not be committed to this repository.
