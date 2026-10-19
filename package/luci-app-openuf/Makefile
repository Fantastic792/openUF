#
# Copyright (C) 2026 Yesrab Ali <yesrab.ali111@gmail.com>
#
# This is free software, licensed under the MIT License.
# See /LICENSE for more information.
#

include $(TOPDIR)/rules.mk

LUCI_TITLE:=LuCI support for openUF (UniFi AP emulation)
LUCI_DESCRIPTION:=A dashboard as LuCI's landing page (health, network path, throughput, radios, clients, controller), overview, settings and log for openUF, and the device page that replaces LuCI's front door once openUF manages the box: status for anyone on the network, settings behind the root password, LuCI one hidden step away.
LUCI_DEPENDS:=+luci-base +openuf +uhttpd-mod-ucode
LUCI_PKGARCH:=all
LUCI_URL:=https://github.com/yesrab/openUF

PKG_VERSION:=0.10.0
PKG_RELEASE:=1
PKG_LICENSE:=MIT
PKG_MAINTAINER:=Yesrab Ali <yesrab.ali111@gmail.com>

# Both scripts must be defined before luci.mk is included: it calls
# BuildPackage at its end, and luci.mk's own postinst is used only when the
# package defines none, so this one repeats its two jobs.
#
# The gate (/usr/share/ucode/openuf/gate.uc) is put into uhttpd's
# configuration by /etc/uci-defaults/80_openuf-portal, which default_postinst
# runs just before this. uhttpd loads a ucode handler once, at start, so:
#   - first install: nothing is restarted, and the device page takes over at
#     the next reboot rather than under an open LuCI session;
#   - upgrade, with uhttpd already running the gate: restarted now, or the
#     old gate keeps answering until the next reboot.
define Package/luci-app-openuf/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
rm -f /tmp/luci-indexcache.*
rm -rf /tmp/luci-modulecache/
/etc/init.d/rpcd reload 2>/dev/null
for pid in $$(pidof uhttpd); do
	if tr '\0' ' ' < /proc/$$pid/cmdline 2>/dev/null | grep -q '/usr/share/ucode/openuf/gate.uc'; then
		/etc/init.d/uhttpd restart >/dev/null 2>&1
		break
	fi
done
exit 0
endef

# Removal (never an upgrade: apk runs no pre-deinstall then, and opkg sets
# PKG_UPGRADE) takes the gate out of uhttpd's configuration: LuCI's own
# ucode entry point goes back where the module is installed, the CGI script
# serves LuCI otherwise, and uhttpd restarts at once so the page does not
# linger until the next reboot. openuf.web belongs to the openuf package and
# is left alone.
define Package/luci-app-openuf/prerm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
[ "$${PKG_UPGRADE}" = 1 ] && exit 0
[ -f /etc/config/uhttpd ] || exit 0
GATE='/cgi-bin/luci=/usr/share/ucode/openuf/gate.uc'
LUCI='/cgi-bin/luci=/usr/share/ucode/luci/uhttpd.uc'
for s in $$(uci -q show uhttpd | sed -n "s/^uhttpd\.\([^.=]*\)=uhttpd$$/\1/p"); do
	case " $$(uci -q get "uhttpd.$$s.ucode_prefix") " in
		*" $$GATE "*)
			uci -q del_list "uhttpd.$$s.ucode_prefix=$$GATE"
			[ -f /usr/share/ucode/luci/uhttpd.uc ] && [ -f /usr/lib/uhttpd_ucode.so ] && \
				uci add_list "uhttpd.$$s.ucode_prefix=$$LUCI"
			;;
	esac
done
uci commit uhttpd
/etc/init.d/uhttpd restart >/dev/null 2>&1
exit 0
endef

# Inside openwrt/luci this is ../../luci.mk; from any other feed, the luci
# feed's copy.
include $(if $(wildcard ../../luci.mk),../../luci.mk,$(TOPDIR)/feeds/luci/luci.mk)

# call BuildPackage - OpenWrt buildroot signature
