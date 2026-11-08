# EzWrt

A LuCI theme for the dedicated EzWrt / PassWall Plus firmware, inspired by the
sidebar and card-based administration experience of Kwrt. EzWrt uses its own
forest-green, teal and lime identity, a compact navigation tree, a branded login
screen, automatic system light/dark appearance, and a collapsible mobile menu.

The theme uses the pinned OpenWrt 25.12 Bootstrap CSS for LuCI widgets. Its header
and footer derive from the Apache-2.0 LuCI Bootstrap templates; authentication,
CSRF tokens, configuration apply/rollback and plugin forms stay in LuCI. All
assets are local; no remote fonts, images, analytics or runtime CDN are used.

The firmware selects EzWrt by default. Installing this theme separately registers
it in **System → System → Language and Style**, without switching the current
style. Bootstrap stays installed as a fallback. Removing EzWrt restores Bootstrap
if EzWrt was selected. The package does not modify network configuration.

The separate firmware overlay in `openwrt/files` sets the hostname and network
mapping. Build and test instructions are in `openwrt/README.md`.

Reference: [Kwrt](https://github.com/kiddin9/Kwrt).
Template foundation: [LuCI Bootstrap](https://github.com/openwrt/luci/tree/openwrt-25.12/themes/luci-theme-bootstrap).
