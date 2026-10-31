#
# Copyright (C) 2026 Yesrab Ali <yesrab.ali111@gmail.com>
#
# This is free software, licensed under the GNU General Public License v3.0 or later.
# See /LICENSE for more information.
#

include $(TOPDIR)/rules.mk

PKG_NAME:=openuf
PKG_VERSION:=0.9.0
PKG_RELEASE:=1

# The release archive tools/release-archive.sh produces from a tag: the
# comment-stripped tree tools/dist.sh --verify proved bytecode-identical to the
# source, under a single openuf-<version>/ directory. The release workflow
# substitutes PKG_VERSION and PKG_HASH from the tag it is building and refuses
# to build with anything but the archive's own sha256. The committed hash is an
# all-zero placeholder, not "skip": a build straight from this tree fails the
# hash check instead of installing an unchecked download. A feed submission
# carries the real hash.
PKG_SOURCE:=openuf-$(PKG_VERSION).tar.gz
PKG_SOURCE_URL:=https://github.com/Fantastic792/openUF/releases/download/v$(PKG_VERSION)/
PKG_HASH:=0000000000000000000000000000000000000000000000000000000000000000

PKG_MAINTAINER:=Yesrab Ali <yesrab.ali111@gmail.com>
# The whole tree, the vendored 802.11r translator included (NOTICE lists the
# copyright holders, and carries the MIT notice for the parts from the
# original openUF).
PKG_LICENSE:=GPL-3.0-or-later
PKG_LICENSE_FILES:=LICENSE NOTICE

include $(INCLUDE_DIR)/package.mk

define Package/openuf
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=Wireless
  TITLE:=UniFi access point emulation
  URL:=https://github.com/Fantastic792/openUF
  # luasec and kmod-leds-gpio are conditional, as in install.sh and setup.sh:
  # luasec only for an https:// inform URL (the UniFi default is plain http),
  # kmod-leds-gpio only on a board whose gpio LEDs the kernel cannot drive.
  # postinst-pkg names either one when this device needs it.
  DEPENDS:=+lua +luabitop +lua-cjson +luasocket +lua-openssl +libuci-lua +iw \
	+lldpd +ip-bridge +hostapd-utils +usteer +nftables +kmod-nft-bridge \
	+tc-tiny +kmod-ifb +kmod-sched-act-police +ucode-mod-socket +kmod-veth
  PKGARCH:=all
endef

define Package/openuf/description
  Makes an OpenWrt access point appear to a UniFi Network Application as a
  Ubiquiti AP (a U6-InWall by default): L2 and L3 adoption, controller-pushed
  SSID and radio settings, client, radio and port statistics.

  Configuration is /etc/config/openuf (a hardware profile from the shipped
  presets or a custom one, the identity to present, the inform URL). The web
  front end is luci-app-openuf.

  Includes the 802.11r translator for roaming between this AP and genuine
  UniFi APs (the openuf-rrb service, see /usr/lib/openuf/rrb/README.md),
  which needs ucode-mod-socket and kmod-veth.

  Needs a FULL wpad build (wpad-openssl, wpad-wolfssl or wpad-mbedtls; a
  wpad-basic-* build rejects the 802.11v option every controller WLAN
  carries and takes the radio down). No dependency can say "any full
  build", so `openuf deps --install` -- also a button on the LuCI
  overview -- replaces the basic build with the full one of the same
  crypto library; the service refuses to start until then.
endef

define Package/openuf/conffiles
/etc/config/openuf
endef

# Sourced by default_postinst on the device (never at image build time):
# the one dependency the package cannot pull in is named, with the fix.
#
# An upgrade restarts what is already running. default_postinst only runs
# `enable` and `start`, and procd ignores a start whose command line has not
# changed, so the old daemon kept running from memory until a reboot: the
# JIDU6401's 0.1.0 -> 0.1.1 upgrade (2026-10-28) left inform.lua on the
# previous build, its status file still naming it. Same as install.sh's
# `restart` (2026-10-26). On a first install nothing is running yet, so
# nothing restarts here and default_postinst starts the services; a service
# the user stopped stays stopped.
define Package/openuf/postinst-pkg
if [ -z "$${IPKG_INSTROOT}" ] && ! grep -q wnm_sleep_mode /usr/sbin/hostapd 2>/dev/null; then
	echo "openuf: hostapd is a basic build (no 802.11v): openUF will not start until a full wpad is installed." >&2
	echo "openuf: run 'openuf deps --install', or use the button on LuCI's openUF overview." >&2
fi
if [ -z "$${IPKG_INSTROOT}" ] && [ -f /opt/openuf/inform.lua ]; then
	echo "openuf: a file install of openUF is also present under /opt/openuf. The service now" >&2
	echo "openuf: runs this package's copy and reads /etc/config/openuf, not /opt/openuf/conf.lua:" >&2
	echo "openuf: carry that configuration over (LuCI: Services > openUF > Settings), then" >&2
	echo "openuf: 'rm -rf /opt/openuf'. Two copies have shown up in a controller as two devices." >&2
fi
if [ -z "$${IPKG_INSTROOT}" ]; then
	_openuf_pm="opkg install"; command -v apk >/dev/null 2>&1 && _openuf_pm="apk add"
	_openuf_url=$$(sed -n 's/.*"inform_url":"\([^"]*\)".*/\1/p' /etc/openuf/state.json 2>/dev/null | head -1)
	[ -n "$$_openuf_url" ] || _openuf_url=$$(uci -q get openuf.main.inform_url)
	case "$$_openuf_url" in
		https*) [ -f /usr/lib/lua/ssl.lua ] \
			|| echo "openuf: the inform URL is https:// and luasec is missing: $$_openuf_pm luasec" >&2 ;;
	esac
	if [ -d /sys/bus/platform/devices/leds ] \
		&& ! ls /sys/class/leds 2>/dev/null | grep -qv '^mt76-'; then
		echo "openuf: this board's gpio LEDs have no driver (Locate cannot light them): $$_openuf_pm kmod-leds-gpio" >&2
	fi
fi
if [ -z "$${IPKG_INSTROOT}" ]; then
	for _openuf_svc in openuf openuf-rrb; do
		if [ -x "/etc/init.d/$$_openuf_svc" ] && "/etc/init.d/$$_openuf_svc" running >/dev/null 2>&1; then
			"/etc/init.d/$$_openuf_svc" restart >/dev/null 2>&1 \
				&& echo "openuf: restarted $$_openuf_svc on the new version" >&2
		fi
	done
fi
endef

# A file install (install.sh's /opt/openuf) is no package, so CONFLICTS cannot
# name it: refuse here instead, before a second copy lands. setup.sh, which
# removes the file install itself once the package is in, leaves the marker.
define Package/openuf/preinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
if [ -f /opt/openuf/inform.lua ] && [ ! -f /opt/openuf/.package-replaces ]; then
	echo "openuf: a file install of openUF is present under /opt/openuf. Remove it first" >&2
	echo "openuf: (sh install.sh uninstall; its state in /etc/openuf stays), then install the" >&2
	echo "openuf: package: two copies have shown up in a controller as two devices." >&2
	exit 1
fi
exit 0
endef

# Removal only (apk runs no pre-deinstall on an upgrade, opkg sets
# PKG_UPGRADE): what install.sh uninstall also undoes beyond the package's own
# files -- the veth pair ucihelper.ensure_ft_veth wrote, the controller's cron
# block, and the bootstrap account, only the one openUF made (its gecos says
# so). default_prerm sources this in a subshell, then stops and disables the
# init scripts. With a file install still present those belong to it.
define Package/openuf/prerm-pkg
if [ -z "$${IPKG_INSTROOT}" ] && [ "$${PKG_UPGRADE}" != 1 ] && [ ! -f /opt/openuf/inform.lua ]; then
	if uci -q get network.openuf_ftveth >/dev/null 2>&1; then
		for _s in openuf_ftveth openuf_ftlink openuf_ftpeer; do uci -q delete network.$$_s; done
		uci commit network
		/etc/init.d/network reload 2>/dev/null
	fi
	if grep -q '^# openuf-cron-begin' /etc/crontabs/root 2>/dev/null; then
		sed -i '/^# openuf-cron-begin/,/^# openuf-cron-end$$/d' /etc/crontabs/root
		/etc/init.d/cron restart 2>/dev/null
	fi
	_gid=$$(awk -F: '$$1=="ubnt" && $$5=="openuf bootstrap adoption" {print $$4}' /etc/passwd 2>/dev/null)
	if [ -n "$$_gid" ]; then
		sed -i '/^ubnt:/d' /etc/passwd /etc/shadow
		sed -i "/^openuf:[^:]*:$$_gid:/d" /etc/group
	fi
	# Not `[ ] && sed` last: a false test would be this file's status, and a
	# failing prerm aborts the removal.
	if [ -f /etc/shells ]; then
		sed -i '/^\/usr\/lib\/openuf\/hook\/adopt-shell\.sh$$/d' /etc/shells
	fi
fi
endef

define Build/Configure
endef

define Build/Compile
endef

define Package/openuf/install
	$(INSTALL_DIR) $(1)/usr/lib/openuf
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/openuf/*.lua $(1)/usr/lib/openuf/
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/openuf/BUILD $(1)/usr/lib/openuf/
	echo "$(PKG_VERSION)" > $(1)/usr/lib/openuf/VERSION
	$(INSTALL_DIR) $(1)/usr/lib/openuf/lib
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/openuf/lib/*.lua $(1)/usr/lib/openuf/lib/
	$(INSTALL_DIR) $(1)/usr/lib/openuf/modelmap
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/openuf/modelmap/*.lua $(1)/usr/lib/openuf/modelmap/
	$(INSTALL_DIR) $(1)/usr/lib/openuf/ufmodel
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/openuf/ufmodel/*.lua $(1)/usr/lib/openuf/ufmodel/
	$(INSTALL_DIR) $(1)/usr/lib/openuf/hook
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/openuf/hook/*.lua $(1)/usr/lib/openuf/hook/
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/openuf/hook/*.sh $(1)/usr/lib/openuf/hook/
	$(INSTALL_DIR) $(1)/usr/bin
	$(LN) ../lib/openuf/hook/syswrapper.sh $(1)/usr/bin/syswrapper.sh
	$(LN) ../lib/openuf/hook/openuf-cli.sh $(1)/usr/bin/openuf
	$(INSTALL_DIR) $(1)/usr/sbin
	$(LN) ../lib/openuf/hook/openuf-convert.sh $(1)/usr/sbin/openuf-convert
	$(LN) ../lib/openuf/hook/openuf-deps.sh $(1)/usr/sbin/openuf-deps
	$(INSTALL_DIR) $(1)/usr/lib/openuf/rrb
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/openuf/rrb/rrb-unifi.uc $(1)/usr/lib/openuf/rrb/
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/openuf/rrb/README.md $(PKG_BUILD_DIR)/openuf/rrb/LICENSE $(1)/usr/lib/openuf/rrb/
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/openuf/etc/init.d/openuf $(1)/etc/init.d/openuf
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/openuf/etc/init.d/openuf-rrb $(1)/etc/init.d/openuf-rrb
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/openuf.config $(1)/etc/config/openuf
	$(INSTALL_DIR) $(1)/etc/openuf
	$(INSTALL_DIR) $(1)/lib/upgrade/keep.d
	$(INSTALL_DATA) ./files/openuf.upgrade $(1)/lib/upgrade/keep.d/openuf
endef

$(eval $(call BuildPackage,openuf))
