--[[
	UAP-AC-LR device identity.

	Used by modelmaps for boards that fit this AP's radio layout. Sourced:
	  • model / platform "U7LR": the controller's own firmware catalog files
	    this AP under that code --
	      fw-update.ubnt.com/api/firmware-latest?filter=eq~~product~~unifi-firmware
	        &filter=eq~~platform~~U7LR&filter=eq~~channel~~release
	    model has to be set: inform.lua defaults a missing one to "U6IW",
	    which paired with this platform names a device that does not exist.
	  • fw.ver: that catalog's release entry (read 2026-11-01). The controller
	    compares the inform's `version` to it with a strict string equality,
	    so it MUST be the bare M.m.p.build form (see uhdiw.lua's header).
	    Re-read the URL above when an "Update Available" banner appears.
	  • fw.buildtime: the catalog's publish timestamp; fw.pre, fw.factoryver:
	    cosmetic, they reach only the L2 discovery TLVs (announce.lua).
	  • required_version and the empty bootver: copied from u6iw, unverified.
	⚠️ NOT validated against a live controller.
]]--

local uap = {}

uap = {
	platform		= "U7LR",
	model			= "U7LR",
	fw				= {
		pre			= "BZ.qca956x.v",
		ver			= "6.8.2.15592",	-- format M.m.p.build -- bare, see header
		buildtime	= "260211.2010",	-- format YYMMDD.HHMM (catalog publish time)
		factoryver	= "3.4.1"
	},
	bootver			= "",
	required_version = "6.0.0",			-- minimum controller version (as u6iw)
}

return uap
