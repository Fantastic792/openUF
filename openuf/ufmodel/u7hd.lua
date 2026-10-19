--[[
	UAP-AC-HD (UniFi AC HD) device identity.

	The WiFi 5 Wave 2 ceiling AP: 802.11ac Wave 2, 4x4 MU-MIMO on both bands
	(1.7 Gbps at 80 MHz on 5 GHz, 800 Mbps at 40 MHz on 2.4 GHz), 802.3at
	PoE+ in, and exactly TWO GbE RJ45 sockets -- "Main" (the PoE-in uplink)
	and "Secondary" (a bridged LAN socket) -- plus a USB-C socket Ubiquiti's
	own quick start guide marks "reserved for future use"
	(techspecs.ui.com/unifi/wifi/uap-ac-hd;
	dl.ubnt.com/qsg/UAP-AC-HD/UAP-AC-HD_EN.html). Ubiquiti's model code is
	U7HD.

	Why a third dual-band identity: the two shipped ones are in-wall APs with
	FIVE sockets (u6iw, uhdiw), the geometry of a 4-LAN + WAN router. A board
	with two sockets reporting either leaves the controller's Ports view
	three rows it will never see a cable in. The UAP-AC-HD is the WiFi 5
	Ubiquiti AP whose socket count matches a two-port board, so its port
	inventory and the modelmap's port table line up one-to-one, and -- as
	with uhdiw -- the controller offers 802.11ac modes an 802.11ac board can
	run, rather than HE ones openUF has to clamp (ucihelper.clamp_htmode).
	Meant for the TP-Link Deco M5 (modelmap/deco-m5.lua): WiFi 5, two GbE
	sockets, and a USB-C of its own that is wired for power only.

	The USB-C socket: nothing to emulate. No AP inform field describes a USB
	socket -- none in the captured informs this project is built on
	(PROTOCOL-VALIDATION.md), and port_table is RJ45 only -- so a controller
	that draws one on the device picture has no state to show for it.
	Reporting nothing IS "always unplugged", and it is also the truth: the
	real UAP-AC-HD's socket does nothing, and the Deco's only carries power.

	Streams: this identity claims 4x4 on both bands; the Deco M5 is 2x2. The
	controller takes nss and rates from radio_table (measured, per radio),
	not from the model code -- the JioRouter maps present a 4x4 AX6000 as a
	2x2 U6-InWall the other way round and nothing objects -- so the mismatch
	only ever shows as "less than a UAP-AC-HD could do".

	⚠️ Adopted by a live controller once so far; u6iw is the identity
	validated end to end. The one: a Deco M4R v1 (user), listed by the
	controller as a UAP-AC-HD on 2026-10-18, with its mesh setting offered,
	and online over a mesh hop on 2026-10-19. Nothing from that run speaks
	to the port questions below yet. What the controller checks is
	sourced, and what it does not is marked as such:
	  • model / platform "U7HD": the controller's own firmware catalog files
	    this AP under that code --
	      fw-update.ubnt.com/api/firmware-latest?filter=eq~~product~~unifi-firmware
	        &filter=eq~~platform~~U7HD&filter=eq~~channel~~release
	    (fetched 2026-10-18).
	  • fw.ver: that catalog's release entry, v6.8.2+15592, created
	    2026-02-11T20:10:34Z -- the same 6.8.2 build the U6-InWall is on
	    (u6iw.lua), which a live controller has already accepted as current.
	    The controller compares the inform's `version` to its catalog entry
	    with a strict, unnormalized string equality (PROTOCOL-VALIDATION.md,
	    "Why version must be bare"), so this MUST be the bare M.m.p.build
	    form and has to track the catalog: a stale value shows a permanent
	    "Update Available" for a fake AP with no firmware to install. Re-read
	    the URL above when the banner appears.
	  • fw.buildtime, fw.factoryver: cosmetic. They reach only the L2
	    discovery TLVs (announce.lua), never the inform. buildtime is the
	    catalog entry's `created` timestamp, not a captured build stamp;
	    factoryver is the 3.7 firmware line this platform launched on in
	    2016/2017 -- 3.7.51.6230 is the oldest release third-party mirrors
	    still list for it; the launch build itself is not public -- not read
	    off a unit.
	  • Copied from u6iw, unverified for this model: fw.pre follows the model
	    code (a real unit's discovery string carries its ipq806x platform
	    prefix instead; the controller does not check it), required_version
	    and the empty bootver.
	  • NOT known: what the model registry gives U7HD for a port count, and
	    whether its Secondary socket counts as a switch port there. Port
	    count and the switch feature decide whether port_table is processed
	    at all (Device.isSwitch(); PROTOCOL-VALIDATION.md, "port_table[]
	    entry"). A real UAP-AC-HD bridges wired hosts on its Secondary socket
	    and the controller lists them under the AP, which is what the
	    registry has to encode for that to work -- an adoption under this
	    identity with a wired host on that socket settles it. If a
	    controller balks, the fallback is one line in the modelmap:
	    ufmodel = "u6iw". The map keeps reporting its
	    two real sockets; the registry's three extra rows simply never link
	    up, as the Xiaomi AX3000T map already lives with for four.
]]--

local uap = {}

uap = {
	platform		= "U7HD",
	model			= "U7HD",
	fw				= {
		pre			= "U7HD.",
		ver			= "6.8.2.15592",	-- format M.m.p.build -- bare, see header
		buildtime	= "260211.2010",	-- format YYMMDD.HHMM (catalog `created` time)
		factoryver	= "3.7.51"
	},
	bootver			= "",
	required_version = "6.0.0",			-- minimum controller version (as u6iw)
}

return uap
