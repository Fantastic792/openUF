#
# Copyright (C) 2026 Yesrab Ali <yesrab.ali111@gmail.com>
#
# This is free software, licensed under the Apache License, Version 2.0.
#

include $(TOPDIR)/rules.mk

LUCI_TITLE:=Halo Theme (in the style of UniFi Network)
LUCI_DESCRIPTION:=A light-and-dark LuCI theme modelled on UniFi Network: a rail of section icons with the section's pages beside it, cards, switches, meters and a floating save bar. Works with any LuCI install; openUF's device page shares its look.
LUCI_DEPENDS:=+luci-base

PKG_VERSION:=1.1.0
PKG_RELEASE:=1
PKG_LICENSE:=Apache-2.0
PKG_MAINTAINER:=Yesrab Ali <yesrab.ali111@gmail.com>

# No csstidy. luci.mk runs every .css under htdocs through csstidy
# --template=highest, which merges selectors that share declarations across
# the whole file (the cascade order goes with it) and rebuilds margin/padding
# shorthands by splitting on spaces -- `margin: calc(-1 * var(--card-py)) ...`
# came out as `margin:calc(-1;`, an unclosed paren that made the browser
# discard the five hundred rules after it. Seen on the v0.2.2 packages (AP2,
# 2026-10-26): an unstyled login page and a sidebar that could not be used.
# luci-theme-footstrap opts out for the same reason. jsmin stays: its output
# for these files is byte-for-byte what the device ran, and it keeps template
# literals and regex literals intact (checked with luci-base's jsmin.c).
LUCI_MINIFY_CSS:=0

# Defined before luci.mk, which calls BuildPackage at its end.
define Package/luci-theme-halo/postrm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	uci -q delete luci.themes.Halo
	uci -q delete luci.themes.HaloDark
	uci -q delete luci.themes.HaloLight
	# Never leave LuCI pointing at a theme that is gone.
	case "$$(uci -q get luci.main.mediaurlbase)" in
		/luci-static/halo*) uci set luci.main.mediaurlbase=/luci-static/bootstrap ;;
	esac
	uci commit luci
}
endef

include $(if $(wildcard ../../luci.mk),../../luci.mk,$(TOPDIR)/feeds/luci/luci.mk)

# call BuildPackage - OpenWrt buildroot signature
