--[[
	The rules openUF keeps in step with the controller's config, moved out of
	inform.lua: guest portal enforcement and its walled garden, blocked
	stations, per-station rate limits (shaper), the per-VAP rules that follow
	a reload. They run on the inform module's own table, so M._guest_*,
	M._deny_* and the rest stay where the tests and the main loop find them.
	Loaded by inform.lua with  _require_sibling("rulesync")(M).
]]--

local util = package.loaded["openuf.util"]
	or assert(loadfile("util.lua") or loadfile("openuf/util.lua"))()
local is_mac = util.is_mac

return function(M)
-- ─── Guest portal enforcement (guestportal.lua) ─────────────────────────────

-- The ledger as a sorted list, for the nft set.
function M._guest_macs(st)
	local out = {}
	for mac in pairs(st.guest_authorized or {}) do out[#out + 1] = mac end
	table.sort(out)
	return out
end

-- The guest WLANs' live netdevs (portal or not), each with its SSID and bridge MAC.
function M._guest_vaps(st)
	local ufuci = M._ucihelper
	if not (ufuci and ufuci.wlanconf_ifnames) then return {} end
	local ok, vaps = pcall(ufuci.wlanconf_ifnames, st.guest_wlans_all or st.guest_wlans)
	if not ok or type(vaps) ~= "table" then return {} end
	for _, v in ipairs(vaps) do v.bridge_mac = M._guestportal.bridge_mac(v.ifname) end
	return vaps
end

local function guest_vaps_key(vaps)
	local parts = {}
	for _, v in ipairs(vaps) do parts[#parts + 1] = v.ifname .. "=" .. tostring(v.bridge_mac) end
	return table.concat(parts, " ")
end

-- While the portal is on: the listening socket (served from M._idle), what
-- the answer needs, and the VAP list the tables were built for.
M._guest_server = nil
M._guest_ctx    = nil
M._guest_built  = nil

-- The walled garden's resolved domain half as reconcile wants it. Empty when
-- the push carries no garden domains, so the rules simply are not there.
function M._guest_garden(st)
	local store = type(st.guest_wg_ips) == "table" and st.guest_wg_ips or {}
	return {
		allowed    = M._guestportal.garden_ips(store.allowed),
		restricted = M._guestportal.garden_ips(store.restricted),
	}
end

-- Resolve the garden's domains and keep the answers in state. Driven on every
-- push and then on the controller's own cadence for the job it asks the device
-- to run (`*/10 * * * *  syswrapper.sh refresh-walled-garden 1`, which
-- sysconf.lua therefore installs no crontab line for). Returns true when the
-- address set changed, i.e. when the chains have to be rebuilt.
--
-- Each name costs two blocking nslookups and a blackholed resolver takes 5 s
-- per lookup, so this is the one path on which the controller can stall the
-- daemon: it runs inline in handle_response, and three missed informs is what
-- puts a genuine AP into selfrun. Two bounds, since neither is enough alone:
--
--  * the NAME LIST's signature, against the refresh window the last pass
--    opened. A push repeats the whole garden whether or not it changed (a
--    Force Provision loop repeats it every few seconds), and re-asking DNS
--    for an unchanged list inside that window buys nothing: the ten-minute
--    refresh is what catches an address that moved. The signature is held in
--    memory, not state.json, because the window is: a restart re-resolves
--    once, which is also when the chains are rebuilt from scratch anyway.
--  * a wall-clock budget per pass. Past it no further name is asked and the
--    rest keep their last answer, which is what a name that stops resolving
--    already does. One name can overrun by a single lookup, so the worst case
--    is BUDGET + 5 s.
M.GUEST_WG_INTERVAL = 600
-- After a pass that ran out of time, rather than ten minutes.
M.GUEST_WG_RETRY = 120
M.GUEST_WG_BUDGET = 5
M._guest_wg_next = 0
M._guest_wg_sig = nil

-- The signature of one push's garden names: the two lists in push order, which
-- is the order they are resolved in, so a reordering is a different list.
local function guest_wg_sig(names)
	local parts = {}
	for _, which in ipairs({"allowed", "restricted"}) do
		parts[#parts + 1] = which .. "=" .. table.concat(names[which], ",")
	end
	return table.concat(parts, " ")
end

function M._guest_wg_resolve(st)
	local gp, spec = M._guestportal, st.guest_portal
	local names = {
		allowed    = (type(spec) == "table" and spec.wg_allowed) or {},
		restricted = (type(spec) == "table" and spec.wg_restricted) or {},
	}
	local now = M._time()
	if #names.allowed == 0 and #names.restricted == 0 then
		M._guest_wg_next = now + M.GUEST_WG_INTERVAL
		M._guest_wg_sig = guest_wg_sig(names)
		if st.guest_wg_ips == nil then return false end
		st.guest_wg_ips = nil
		M._state.save(st)
		return true
	end
	local sig = guest_wg_sig(names)
	if sig == M._guest_wg_sig and M._not_due(M._guest_wg_next, now,
		math.max(M.GUEST_WG_INTERVAL, M.GUEST_WG_RETRY)) then return false end
	local store = type(st.guest_wg_ips) == "table" and st.guest_wg_ips or {}
	local changed, partial = false, false
	local out = {}
	for _, which in ipairs({"allowed", "restricted"}) do
		-- One budget for the pass, not one per list: what is left of it after
		-- the allowed names is what the restricted ones get.
		local left = M.GUEST_WG_BUDGET - (M._time() - now)
		local map, _, diff, cut = gp.resolve_garden(names[which], store[which],
			left > 0 and left or 0)
		out[which] = map
		changed = changed or diff
		partial = partial or cut
	end
	M._guest_wg_sig = sig
	-- A pass that ran out of time opens a shorter window, so the names it
	-- never asked are picked up by the heartbeat in two minutes rather than
	-- ten -- without letting every push in between re-ask.
	M._guest_wg_next = M._time()
		+ (partial and M.GUEST_WG_RETRY or M.GUEST_WG_INTERVAL)
	if changed then
		st.guest_wg_ips = out
		M._state.save(st)
	end
	return changed
end

-- The ten-minute refresh itself, from the heartbeat.
function M._guest_wg_resync(st)
	local spec = st and st.guest_portal
	if not (M._guestportal and type(spec) == "table" and spec.enabled) then return false end
	-- Length without the `or {}` fallbacks: a portal with no garden is the
	-- common case, and that is exactly when both fields are nil, so the guard
	-- that exists to do nothing allocated two tables per heartbeat.
	if (spec.wg_allowed and #spec.wg_allowed or 0) == 0
		and (spec.wg_restricted and #spec.wg_restricted or 0) == 0 then return false end
	if M._not_due(M._guest_wg_next, M._time(),
		math.max(M.GUEST_WG_INTERVAL, M.GUEST_WG_RETRY)) then return false end
	if not M._guest_wg_resolve(st) then return false end
	io.stderr:write("guestportal: walled-garden addresses changed -- rebuilding\n")
	M._guest_enforce(st)
	return true
end

-- Make the kernel and the listener match st.guest_portal.
function M._guest_enforce(st, vaps)
	local gp = M._guestportal
	local spec = st.guest_portal
	if not (type(spec) == "table" and spec.enabled) then
		gp.reconcile(nil)
		M._guest_built, M._guest_ctx = nil, nil
		if M._guest_server then M._guest_server:close() end
		M._guest_server = nil
		return 0
	end
	if spec.portal == false then
		-- Restrictions only: no token, no listener, no selfrun.
		vaps = vaps or M._guest_vaps(st)
		local n = gp.reconcile(spec, vaps, M._guest_macs(st), false, M._guest_garden(st))
		M._guest_built, M._guest_ctx = guest_vaps_key(vaps), nil
		if M._guest_server then M._guest_server:close() end
		M._guest_server = nil
		return n
	end
	-- The portal's guest_token (build_json). Its value would key the
	-- controller's encrypted-cookie redirect, which openUF does not claim;
	-- the plain id=/ap= redirect only needs one to exist.
	if type(st.guest_token) ~= "string" then
		local bytes = M._crypto.random_iv(16)
		st.guest_token = (bytes:gsub(".", function(c) return string.format("%02x", c:byte()) end))
		M._state.save(st)
	end
	vaps = vaps or M._guest_vaps(st)
	local n = gp.reconcile(spec, vaps, M._guest_macs(st), M._guest_selfrun_on,
		M._guest_garden(st))
	M._guest_built = guest_vaps_key(vaps)
	M._guest_ctx = {url = spec.url, ap = st.mac, vaps = vaps}
	if not M._guest_server then
		local ok, server, err = pcall(gp.listen, M._socket())
		if ok and server then
			M._guest_server = server
		else
			io.stderr:write("guestportal: cannot listen on port " .. gp.PORT .. ": "
				.. tostring(ok and err or server) .. "\n")
		end
	end
	return n
end

M._socket = function() return require("socket") end

-- A push's portal facts -> st.guest_portal, and the kernel made to match.
-- A push without redirector.status (a partial one) leaves it alone.
function M._guest_apply_push(sys_raw, st)
	local spec = M._guestportal.parse(sys_raw)
	if not spec then return false end
	for _, u in ipairs(spec.unknown) do
		io.stderr:write("guestportal: unrecognised guest rule shape, not applied: "
			.. ("%q"):format(u) .. "\n")
	end
	spec.unknown = nil
	st.guest_portal = spec.enabled and spec or nil
	-- Before the rebuild, so this push's garden is enforced by it rather than
	-- ten minutes later.
	pcall(M._guest_wg_resolve, st)
	M._guest_enforce(st)
	return true
end

-- Once a minute while the portal is on: rebuild when the guest VAPs' netdevs
-- changed (a push's `wifi reload` finishing, wireless coming up after the
-- daemon). An empty list is "not answering yet" and changes nothing.
M.GUEST_RESYNC_INTERVAL = 60
M._guest_next = 0
function M._guest_resync(st)
	local spec = st and st.guest_portal
	if not (M._guestportal and type(spec) == "table" and spec.enabled) then return false end
	local now = M._time()
	if M._not_due(M._guest_next, now, M.GUEST_RESYNC_INTERVAL) then return false end
	M._guest_next = now + M.GUEST_RESYNC_INTERVAL
	local vaps = M._guest_vaps(st)
	if #vaps == 0 or guest_vaps_key(vaps) == M._guest_built then return false end
	io.stderr:write("guestportal: guest interfaces changed (" .. guest_vaps_key(vaps)
		.. ") -- rebuilding\n")
	M._guest_enforce(st, vaps)
	return true
end

-- selfrun_guest_mode (mgmt_cfg, every push): what guests get while the AP
-- runs without its controller, as the UniFi firmware does it (mcad +
-- syswrapper.sh, BZ2 3.9.27-4.0.15). Selfrun starts after
-- GUEST_SELFRUN_FAILS informs in a row went unanswered and ends with the
-- first answer; it only matters while the portal is on. "pass" (or never
-- told -- only "off" is off) lets every guest through
-- (guestportal.set_selfrun), since nobody could log in meanwhile. "off"
-- takes the guest WLANs down until the controller is back; the ifnames are
-- kept in st.guest_vaps_down, so a restart in between still brings them up.
-- Unlike the firmware, the authorized ledger is kept on return: the
-- controller re-authorizes the same guests anyway.
M.GUEST_SELFRUN_FAILS = 3
M._inform_fails = 0
M._guest_selfrun_on = false
M._guest_up_failed = ""
function M._guest_selfrun(st, contacted)
	M._inform_fails = contacted and 0 or M._inform_fails + 1
	local spec = st and st.guest_portal
	-- WLANs left down before a restart stay down until an answer, rather
	-- than flapping up for the first failures of the new count.
	local selfrun = M._inform_fails >= M.GUEST_SELFRUN_FAILS
		or (st.guest_vaps_down ~= nil and not contacted)
	local mode
	if type(spec) == "table" and spec.enabled == true and spec.portal ~= false and selfrun then
		mode = (st.guest_selfrun == "off") and "off" or "pass"
	end
	local changed = false
	if mode == "off" and not st.guest_vaps_down then
		local names = {}
		for _, v in ipairs(M._guest_vaps(st)) do names[#names + 1] = v.ifname end
		for _, n in ipairs(names) do pcall(M._wlansched.set_bss, n, false) end
		st.guest_vaps_down = names
		M._state.save(st)
		io.stderr:write("guestportal: " .. M._inform_fails .. " informs unanswered, "
			.. "selfrun_guest_mode=off -- guest WLANs down (" .. table.concat(names, " ") .. ")\n")
		changed = true
	elseif mode ~= "off" and st.guest_vaps_down then
		-- A WLAN its blackout schedule or the Uplink Connectivity Monitor
		-- holds down stays down (each brings it up when it lets go). One whose
		-- beacon did not restart (wlansched.set_bss) stays in the ledger,
		-- down, and the next answered inform tries again.
		local held, up, failed = {}, {}, {}
		for _, n in ipairs(st.sched_vaps_down or {}) do held[n] = true end
		for _, n in ipairs(st.uplinkmon_down or {}) do held[n] = true end
		for _, n in ipairs(st.guest_vaps_down) do
			-- Already up (a wifi reload recreated it) or gone: nothing to do.
			if not held[n] and M._wlansched.is_up(n) == false then
				local ok, res = pcall(M._wlansched.set_bss, n, true)
				if ok and res then up[#up + 1] = n else failed[#failed + 1] = n end
			end
		end
		if #up > 0 then
			io.stderr:write("guestportal: guest WLANs back up (" .. table.concat(up, " ") .. ")\n")
		end
		-- Said once per set of failures, not on every retry.
		local said = table.concat(failed, " ")
		if #failed > 0 and said ~= M._guest_up_failed then
			io.stderr:write("guestportal: could not put guest WLANs back on the air ("
				.. said .. ") -- retrying at every answer\n")
		end
		M._guest_up_failed = said
		st.guest_vaps_down = (#failed > 0) and failed or nil
		M._state.save(st)
		changed = true
	end
	local pass = mode == "pass"
	if pass ~= M._guest_selfrun_on then
		M._guest_selfrun_on = pass
		io.stderr:write(pass
			and ("guestportal: " .. M._inform_fails .. " informs unanswered, "
				.. "selfrun_guest_mode=pass -- letting guests through\n")
			or "guestportal: controller answered -- guest portal enforced again\n")
		if M._guest_built then pcall(M._guestportal.set_selfrun, pass) end
		changed = true
	end
	return changed
end

-- The guest's SSID for the portal's ssid=: the only one, or the VAP that
-- has the station.
M._station_on = function(ifname, mac)
	-- A shell command line: a netdev name and a MAC only.
	if not (util.valid_ifname(ifname) and is_mac(mac)) then return false end
	local p = io.popen("iw dev " .. ifname .. " station get " .. mac .. " 2>/dev/null")
	if not p then return false end
	local out = p:read("*a") or ""
	p:close()
	return out:find("Station", 1, true) ~= nil
end

function M._guest_ssid_for(vaps, mac)
	local first, single = nil, true
	for _, v in ipairs(vaps or {}) do
		if first == nil then first = v.ssid elseif v.ssid ~= first then single = false end
	end
	if single then return first end
	for _, v in ipairs(vaps) do
		if v.ifname:match("^[%w%-%._]+$") and M._station_on(v.ifname, mac) then return v.ssid end
	end
	return first
end

M._read_arp = function()
	local f = io.open("/proc/net/arp", "r")
	if not f then return "" end
	local s = f:read("*a")
	f:close()
	return s or ""
end

-- Answer one guest on the portal's listening socket. True when one was
-- served; false when the socket was readable with nothing to accept.
function M._guest_serve(server)
	local ctx = M._guest_ctx or {}
	local ok, served = pcall(M._guestportal.serve_one, server, {
		url = ctx.url, ap = ctx.ap,
		ssid_for = function(mac) return M._guest_ssid_for(ctx.vaps, mac) end,
		arp = M._read_arp, now = M._time,
	})
	return ok and served and true or false
end

-- Replace the block ledger with the controller's list (setparam blocked_sta)
-- and rebuild the nft set, but only when the set of MACs changed: reconcile
-- drops and recreates the table, so redoing it on every push would open a
-- gap for nothing. A MAC new to the ledger is deauthed as block-sta does.
-- Returns true when the ledger changed.
function M._sync_blocked_stas(st, raw)
	local list, want = {}, {}
	for line in (raw .. "\n"):gmatch("([^\n]*)\n") do
		local mac = line:lower():match("^%s*(%x%x:%x%x:%x%x:%x%x:%x%x:%x%x)%s*$")
		if mac then
			if not want[mac] then want[mac] = true; list[#list + 1] = mac end
		elseif line:match("%S") then
			io.stderr:write(("inform: blocked_sta: ignoring %q\n"):format(line))
		end
	end
	local have, n_have = {}, 0
	for _, m in ipairs(st.blocked_stas or {}) do
		m = tostring(m):lower()
		if not have[m] then have[m] = true; n_have = n_have + 1 end
	end
	local changed = (n_have ~= #list)
	for _, m in ipairs(list) do
		if not have[m] then changed = true break end
	end
	if not changed then return false end
	st.blocked_stas = list
	M._firewall.reconcile(list)
	M._deny_pending = true
	pcall(M._block_resync, st)
	local ifnames
	for _, m in ipairs(list) do
		if not have[m] then
			ifnames = ifnames or M._bss_ifnames()
			M._firewall.deauth(m, ifnames)
		end
	end
	return true
end

-- A rate-update into st.sta_rates ({mac = {up = kbps, down = kbps}}), for
-- any client, as the firmware's update_sta_qosrate takes it: a limit of 0
-- or less, or none, is -1, which lifts that client's cap that way even on a
-- limited WLAN. Ignored for a MAC no netdev listed at the last heartbeat,
-- as the firmware ignores one with no association. Returns true when the
-- ledger changed.
function M._sta_rate(st, resp)
	local mac = type(resp.mac) == "string"
		and resp.mac:lower():match("^%s*(%x%x:%x%x:%x%x:%x%x:%x%x:%x%x)%s*$")
	if not mac then return false end
	local obs = M._shape_obs
	if obs and obs.complete and not obs.where[mac] then return false end
	local function kbps(v)
		v = tonumber(v)
		return v and v > 0 and math.floor(v) or -1
	end
	local up, down = kbps(resp.ul_max), kbps(resp.dl_max)
	st.sta_rates = st.sta_rates or {}
	local cur = st.sta_rates[mac]
	if cur and cur.up == up and cur.down == down then return false end
	st.sta_rates[mac] = {up = up, down = down}
	return true
end

-- WiFi Speed Limit, from what the last build_json saw (M._shape_obs): each
-- netdev's stations and its WLAN's limits, with st.sta_rates on top. A
-- rate-update lasts one association, as the firmware's per-station class
-- does: it goes when the client leaves, or when its connected time drops
-- (it reconnected between two heartbeats; the controller sends a fresh
-- one if the client still has a profile of its own).
M._sta_conn = {}
function M._shaper_resync(st)
	local obs = M._shape_obs
	if not obs then return false end
	local shaper = M._shaper
	if not shaper then return false end
	local rates = st.sta_rates or {}
	local changed = false
	if obs.complete then
		for mac in pairs(rates) do
			local now_c, was_c = obs.conn[mac], M._sta_conn[mac]
			if not obs.where[mac] or (now_c and was_c and now_c < was_c) then
				rates[mac] = nil
				changed = true
			end
		end
		M._sta_conn = obs.conn
	end
	local desired = {}
	for ifname, o in pairs(obs.by_ifname) do
		local down = {default = o.down, stas = {}}
		local up = {default = o.up, stas = {}}
		for _, mac in ipairs(o.macs) do
			local r = rates[mac]
			local d, u = o.down, o.up
			-- An own limit replaces the WLAN's; -1 lifts it (0: uncapped).
			if r then
				d = r.down and r.down > 0 and r.down or 0
				u = r.up and r.up > 0 and r.up or 0
			end
			down.stas[mac], up.stas[mac] = d, u
		end
		local any = down.default or up.default
		for _, k in pairs(down.stas) do any = any or (k and k > 0) end
		for _, k in pairs(up.stas) do any = any or (k and k > 0) end
		if any then
			desired[ifname] = {down = down, up = up}
		end
	end
	if changed then
		st.sta_rates = next(rates) and rates or nil
		M._state.save(st)
	end
	-- sync is false when a netdev did not end up as wanted. Logged when it
	-- starts and when it clears, not on every heartbeat.
	local ok = shaper.sync(desired) ~= false
	if ok ~= not M._shaper_failed then
		M._shaper_failed = not ok
		io.stderr:write(ok and "inform: shaper: rate limits applied again\n"
			or "inform: shaper: a rate limit did not apply (tc refused it)\n")
	end
	return ok
end

-- A block's refusal in hostapd (firewall.deny_sync) is lost whenever hostapd
-- restarts or reloads a BSS. A sync forks a shell, one hostapd_cli per BSS
-- and a grep, so while anything is blocked it runs:
--   - every tick while _deny_pending: set at startup (entries from before a
--     restart get looked at), by a block change and a state reload, and kept
--     by a sync that did not settle (a BSS that did not answer, a change still
--     to read back), until a pass finds nothing left to clean;
--   - on any tick that finds a hostapd control socket replaced (a restart, a
--     BSS rebuilt: firewall.hostapd_sockets, a file read);
--   - every tick for DENY_SETTLE seconds after openUF's own `wifi reload`
--     (_deny_reloaded), which lands asynchronously and can reload a BSS in
--     place, keeping its socket;
--   - and otherwise every DENY_INTERVAL seconds, the bound on a reload in
--     place that openUF did not run (LuCI, a `wifi reload` by hand). Until
--     then the client can associate, and the nft drop still stops its traffic.
M.DENY_INTERVAL = 60
M.DENY_SETTLE   = 60
-- The per-VAP rule resyncs below (guest portal, l2guard, broadcast filter,
-- hairpin, usteer filter) each wait up to 60 s on a timer that nothing reset
-- when a VAP appeared. After a `wifi reload` netifd raises VAPs
-- asynchronously (a DFS radio can take over a minute), so a new or renamed
-- VAP ran without its nft rules for up to a minute. _vap_watch opens their
-- gates on the tick the VAP name set changes, and on every tick for
-- VAP_SETTLE after a reload. Each resync still rebuilds only on a real change.
M.VAP_SETTLE = 60
M._vap_settle_until = nil
M._vaps_sig = nil
function M._vap_rules_due()
	M._guest_next, M._l2guard_next, M._bcfilt_next = 0, 0, 0
	M._hairpin_next, M._usteer_filter_next = 0, 0
end
function M._vap_watch(now)
	local sig = table.concat(M._l2guard_live_ifnames(), " ")
	if sig ~= M._vaps_sig then
		M._vaps_sig = sig
		M._vap_rules_due()
		return true
	end
	-- _not_due also rejects a window a clock stepped back a day would stretch.
	if M._vap_settle_until and M._not_due(M._vap_settle_until, now, M.VAP_SETTLE) then
		M._vap_rules_due()
		return true
	end
	return false
end
M._deny_pending = true
M._deny_at, M._deny_socks, M._deny_settle = nil, nil, nil
function M._deny_reloaded()
	M._deny_settle = M._time() + M.DENY_SETTLE
	M._vap_settle_until = M._time() + M.VAP_SETTLE
end
function M._block_resync(st)
	local list = st and st.blocked_stas or {}
	if #list == 0 and not M._deny_pending then return false end
	local now = M._time()
	local socks = M._firewall.hostapd_sockets()
	local since = M._deny_at and now - M._deny_at
	local settle = M._deny_settle and M._deny_settle - now
	local due = M._deny_pending or socks ~= M._deny_socks
		or not since or since < 0 or since >= M.DENY_INTERVAL
		-- A clock stepped back must not stretch the window.
		or (settle and settle > 0 and settle <= M.DENY_SETTLE)
	if not due then return false end
	M._deny_at, M._deny_socks = now, socks
	M._deny_pending = M._firewall.deny_sync(list, M._bss_ifnames())
	return true
end

function M._bss_ifnames()
	local ufuci = M._ucihelper
	if not (ufuci and ufuci.ap_ifnames) then return {} end
	local ok, names = pcall(ufuci.ap_ifnames)
	if not ok or type(names) ~= "table" then return {} end
	local out, seen = {}, {}
	for _, name in ipairs(names) do
		local bss = ufuci.bss_ifname and ufuci.bss_ifname(name) or name
		if not seen[bss] then
			seen[bss] = true
			out[#out + 1] = bss
		end
	end
	return out
end
end
