--[[
	UAP-LR (first-generation UniFi AP, long range) device identity.

	Used by modelmaps for boards that fit this AP's radio layout. Sourced:
	  • model / platform "BZ2LR": the controller's own firmware catalog files
	    this AP under that code --
	      fw-update.ubnt.com/api/firmware-latest?filter=eq~~product~~unifi-firmware
	        &filter=eq~~platform~~BZ2LR&filter=eq~~channel~~release
	    model has to be set: inform.lua defaults a missing one to "U6IW",
	    which paired with this platform names a device that does not exist.
	  • fw.ver: that catalog's release entry (read 2026-11-01). The controller
	    compares the inform's `version` to it with a strict string equality,
	    so it MUST be the bare M.m.p.build form (see uhdiw.lua's header).
	    Re-read the URL above when an "Update Available" banner appears.
	  • fw.buildtime: the catalog's publish timestamp; fw.pre, fw.factoryver:
	    cosmetic, they reach only the L2 discovery TLVs (announce.lua).
	  • required_version and the empty bootver: copied from u6iw, unverified.
	⚠️ The catalog's last BZ2LR release is from 2021: current Network
	applications may no longer adopt this model at all. NOT validated.
]]--

local uap = {}

uap = {
	platform		= "BZ2LR",
	model			= "BZ2LR",
	fw				= {
		pre			= "BZ.ar7240.v",
		ver			= "4.3.28.11361",	-- format M.m.p.build -- bare, see header
		buildtime	= "210210.0903",	-- format YYMMDD.HHMM (catalog publish time)
		factoryver	= "2.4.4"
	},
	bootver			= "",
	required_version = "6.0.0",			-- minimum controller version (as u6iw)
}

return uap
