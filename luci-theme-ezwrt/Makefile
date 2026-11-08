include $(TOPDIR)/rules.mk

PKG_NAME:=luci-theme-ezwrt
PKG_VERSION:=1.0.0
PKG_RELEASE:=1
PKG_LICENSE:=Apache-2.0

LUCI_TITLE:=EzWrt Theme
LUCI_DEPENDS:=+luci-base +luci-theme-bootstrap
LUCI_PKGARCH:=all

# Preserve modern CSS and ship source templates for the target LuCI runtime.
CONFIG_LUCI_CSSTIDY:=
CONFIG_LUCI_UTMIN:=
LUCI_MINIFY_UT:=0

define Package/$(PKG_NAME)/postrm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	if [ "$$(uci -q get luci.main.mediaurlbase)" = '/luci-static/ezwrt' ]; then
		uci set luci.main.mediaurlbase='/luci-static/bootstrap'
	fi
	uci -q delete luci.themes.EzWrt
	uci commit luci
}
endef

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt feed scanner marker.
