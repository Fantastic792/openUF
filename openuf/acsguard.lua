-- acsguard.lua -- a radio left on Auto whose hostapd channel selection gave up.
--
-- With channel=auto hostapd's ACS picks the channel at bring-up. When it
-- cannot (on mwl8k it chose 48 for HT40, which has no upper neighbour there,
-- and stopped: antoniocosta/unifi-openwrt 4ba788e) the radio's WLANs stay off
-- the air while netifd still reports the radio up, and nothing tries again.
-- A radio that stays so for WAIT seconds gets a fixed channel, pinned in UCI
-- by ucihelper.acs_pin until the controller sends a fixed channel or the
-- device is forgotten. Pure logic: ucihelper finds the radios and writes UCI.
local M = {}

-- A radio is without a channel for some seconds every time it comes up.
M.WAIT = 60

-- Non-DFS channels that start a block at every width (20, 40 and 80 MHz on
-- 5 GHz), so the pick cannot fall into the width trap that stopped ACS, nor
-- wait out a radar check.
-- shortcut: the first usable candidate, not the least busy one; use the scan
-- cache if pinned radios turn out to share a crowded channel.
M.CANDIDATES = {ng = {1, 6, 11}, na = {36, 149}}

-- The first candidate of the band the radio may use: in `legal` (the
-- regdomain's channels from phy_caps) and, when the radio has one, in its
-- `chanlist` (the site's blacklist turned into a candidate list). nil when
-- nothing fits: refuse rather than guess.
function M.pick(band, legal, chanlist)
	local ok = {}
	for _, c in ipairs(type(legal) == "table" and legal or {}) do ok[tonumber(c) or -1] = true end
	local allow = nil
	if type(chanlist) == "table" and #chanlist > 0 then
		allow = {}
		for _, c in ipairs(chanlist) do allow[tonumber(c) or -1] = true end
	end
	for _, c in ipairs(M.CANDIDATES[band] or {}) do
		if ok[c] and (not allow or allow[c]) then return c end
	end
	return nil
end

-- failing: radios on Auto with no live channel now, {{name, band, legal,
-- chanlist}} (ucihelper.acs_failing). since: name -> when first seen so,
-- updated in place; a radio that got a channel back is dropped from it.
-- Returns {{name, channel}} to pin now.
function M.decide(failing, since, now)
	local out, seen = {}, {}
	for _, r in ipairs(failing) do
		seen[r.name] = true
		since[r.name] = since[r.name] or now
		if now - since[r.name] >= M.WAIT then
			since[r.name] = nil
			local ch = M.pick(r.band, r.legal, r.chanlist)
			if ch then out[#out + 1] = {name = r.name, channel = ch} end
		end
	end
	for n in pairs(since) do
		if not seen[n] then since[n] = nil end
	end
	return out
end

return M
