include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-passwall-ezcnet
PKG_VERSION:=0.2.0
PKG_RELEASE:=1
PKG_LICENSE:=GPL-3.0-only

LUCI_TITLE:=passwall-EzCNet cloud management
LUCI_DEPENDS:=+luci-compat +luci-lib-jsonc +luci-lib-nixio +libuci-lua +curl +ca-bundle +coreutils-timeout +luci-app-passwall
LUCI_PKGARCH:=all

define Package/$(PKG_NAME)/conffiles
/etc/config/passwall_ezcnet
/etc/passwall_ezcnet/
endef

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt's feed scanner requires this marker for luci.mk.
