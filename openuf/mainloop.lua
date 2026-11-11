--[[
	The rest of the inform module's work, moved out of inform.lua: the dfs-reset
	and neighbour-sweep helpers, the notification queue, the heartbeat tick and
	the startup/shutdown path. They run on the inform module's own table, so
	the M._* names the tests and the entry point use stay where they were.
	Loaded by inform.lua with  _require_sibling("mainloop")(M).
]]--

local util = package.loaded["openuf.util"]
	or assert(loadfile("util.lua") or loadfile("openuf/util.lua"))()
local cjson = require("cjson")

return function(M)
local state, RRM_MAX_AGE = M._state, M.RRM_MAX_AGE
-- ─── dfs-reset ───────────────────────────────────────────────────────────────
-- The controller's 02:00 cron job, pushed whenever the site has a 5 GHz radio
-- pinned to a fixed DFS channel (the gate is decompiled in
-- PROTOCOL-VALIDATION.md, "Axis 4"). What it is for: a radar hit takes the
-- radio off that channel and nothing brings it back, so the carefully planned
-- cell quietly stays on whatever channel the driver picked -- until the next
-- Force Provision, which may be months away.
--
-- U7LR 6.8.2's own dfs_reset is the model, verb for verb (bin/syswrapper.sh):
-- for each 5 GHz radio's first VAP in Master mode, compare the live channel
-- against the one the controller configured, skip `auto` and `0`, skip when
-- they already agree, skip while the configured channel is still on the
-- non-occupancy list ("still in nol_channel, wait next time"), and otherwise
-- put the radio back. The firmware uses `radartool chknol` and `iwconfig
-- channel`; the equivalents here are mac80211's per-channel DFS state and a
-- CSA through hostapd's control socket.
--
-- Deliberately a channel switch announcement rather than a `wifi reload`: the
-- BSS is never torn down, associated clients are told where it is going, and
-- UCI is not touched (it already holds the configured channel -- that is what
-- makes this a *reset*). The radio still goes quiet for the CAC on arrival,
-- which is the price of a DFS channel and the reason this runs at 02:00.
M.DFS_RESET_REQUEST_FILE = "/tmp/openuf-dfs-reset-request"
-- The kernel's non-occupancy period after a radar hit (IEEE80211_DFS_MIN_NOP_TIME_MS,
-- 30 minutes), for telling the operator how long is left.
M.DFS_NOP_S = 1800
-- A request the daemon never saw (it was down, or the whole AP was) is not
-- carried out hours later, when the clock has moved on and the controller
-- would schedule a fresh one the next night anyway.
M.DFS_RESET_MAX_AGE = 1800

-- True when the hook left a request that is still fresh. The file is removed
-- either way, so one request is served at most once.
function M._dfs_reset_requested()
	local raw = M._read_file(M.DFS_RESET_REQUEST_FILE)
	if not raw then return false end
	os.remove(M.DFS_RESET_REQUEST_FILE)
	local at = tonumber(raw:match("%d+"))
	if not at then return false end
	local late = M._time() - at
	if late > M.DFS_RESET_MAX_AGE or late < -60 then
		io.stderr:write("inform: ignoring a stale dfs-reset request\n")
		return false
	end
	return true
end

-- One radio: put it back on `want` if it is somewhere else and allowed to be
-- there. Returns "moved", or nil plus the reason it was left alone.
function M._dfs_reset_radio(radio, ifname)
	local rrm, si = M._rrmscan, M._sysinfo
	local want = tonumber(radio.channel)
	if not want then return nil, "channel is not pinned" end

	local caps = si.radio_caps(ifname) or {}
	local live = tonumber(caps.channel)
	if not live then return nil, "no live channel" end
	if live == want then return nil, nil end

	if rrm.is_dfs_channel(want) then
		local states = rrm.parse_dfs_states(si.phy_channels(ifname))
		if rrm.channel_in_nol(states, want) then
			local s = states[want] or {}
			-- iw's "(for N sec)" is how long the channel has BEEN in this state
			-- (NL80211_FREQUENCY_ATTR_DFS_TIME), not how long is left.
			local left = s.secs and math.max(0, M.DFS_NOP_S - s.secs)
			io.stderr:write(("inform: dfs-reset: %s is on channel %d, wants %d,"
				.. " but %d is still on the non-occupancy list%s -- waiting for"
				.. " the next run\n"):format(ifname, live, want, want,
				s.secs and (" (unavailable for " .. s.secs .. " s, about "
					.. left .. " s left)") or ""))
			return nil, "in the non-occupancy list"
		end
	end

	local args = rrm.chan_switch_args(want, caps.width)
	if not args then
		io.stderr:write(("inform: dfs-reset: %s: cannot express channel %d at %s"
			.. " MHz as a channel switch -- leaving it on %d\n")
			:format(ifname, want, tostring(caps.width), live))
		return nil, "not expressible as a channel switch"
	end
	if not util.valid_ifname(ifname) then return nil, "not a netdev name" end
	local cmd = "hostapd_cli -i " .. ifname .. " chan_switch "
		.. rrm.CS_COUNT .. " " .. args
	local out = M._run_cmd(cmd .. " 2>&1") or ""
	if not out:find("OK", 1, true) then
		io.stderr:write(("inform: dfs-reset: %s: hostapd refused the switch to"
			.. " channel %d (%s): %s\n"):format(ifname, want, args,
			(out:gsub("%s+$", ""))))
		return nil, "hostapd refused the switch"
	end
	io.stderr:write(("inform: dfs-reset: %s switching back from channel %d to"
		.. " the configured %d (%s)\n"):format(ifname, live, want, args))
	return "moved"
end

-- Serve a pending dfs-reset request. Returns how many radios were moved.
function M._maybe_service_dfs_reset(cfg)
	if not M._dfs_reset_requested() then return 0 end
	local ufuci, rrm, si = M._ucihelper, M._rrmscan, M._sysinfo
	if not (ufuci and rrm and si and si.phy_channels) then return 0 end
	local ok_r, radios = pcall(ufuci.get_radio_table, cfg and cfg.uap and cfg.uap.hwassign)
	if not ok_r or type(radios) ~= "table" then return 0 end
	local moved = 0
	for _, radio in ipairs(radios) do
		-- 5 GHz only, as the firmware's own list_first_vaps_ifs 5 does: no
		-- other band has DFS, so no other band can have been pushed off a
		-- channel by radar.
		if radio.radio == "na" and not radio.disabled then
			local ok_if, ifname = pcall(ufuci.get_ifname_for_radio, radio.name)
			if ok_if and ifname then
				local ok_m, what = pcall(M._dfs_reset_radio, radio, ifname)
				if ok_m and what == "moved" then moved = moved + 1 end
			end
		end
	end
	return moved
end

-- One heartbeat: build, send, dispatch. Returns the number of seconds the
-- caller should wait before the next one -- 0 means "again, now", the
-- config-applied case, where a real AP re-informs immediately. ctx carries the
-- loop's own state (interval, backoff, last_mtime) so run() is nothing but
-- `while true do wait(_tick()) end`, and the error boundaries and the backoff
-- can be exercised without a socket.

-- One cycle of the client-assisted enrichment: keep the notification
-- collector alive, fold in whatever clients have reported since last time,
-- expire what the controller would discard anyway, and -- at most every
-- rrm_request_interval -- ask one more station to go and look.
--
-- The hostapd event collector serves two consumers: 802.11k enrichment
-- (rrm_enrichment) and connection tracking (assoctrack). It runs while either
-- wants it, and the file it fills is drained once per heartbeat for both.
--
-- Everything here is pcall-wrapped and best-effort: no hostapd, no ubus, no
-- capable client and no answer are all ordinary outcomes, and none of them may
-- interrupt an inform. Returns true when either consumer is on.
function M._rrm_tick(cfg, st)
	local rrm = M._rrmscan
	if not rrm then return false end
	if not (cfg and cfg.config) then return false end
	-- Off only when conf.lua says `false`. An ABSENT key means the documented
	-- default (on): install.sh keeps a device's existing conf.lua across
	-- upgrades, so every device installed before this option existed has no
	-- such key -- AP2 was exactly that, and the collector never started.
	local rrm_on   = cfg.config.rrm_enrichment ~= false
	local assoc_on = M._assoc_enabled(st, cfg)
	M._roam_fast, M._roam_st = assoc_on and rrm.drain ~= nil, st
	M._roam_keep = rrm_on and true or false
	if not (assoc_on and rrm_on) then M._pre_blob = nil end
	local now = M._time()
	-- A radio that can see radar is a third consumer of the control-socket
	-- monitors, alongside 802.11k enrichment and connection tracking. Without
	-- it in this condition the whole path below is skipped -- and the branch
	-- stops the collector and deletes the event file -- so on a site with
	-- neither of the other two the radar event would never be sent.
	local dfs_on = M._dfs_radio and true or false
	if not rrm_on and not assoc_on and not dfs_on then
		-- Off -- but a collector started while it was ON is a detached `ubus
		-- subscribe` child, reparented to init, appending to a file on a RAM
		-- disk that harvest() -- the only thing that ever truncates it -- no
		-- longer drains. rrmscan.collector_stop() existed and had no caller;
		-- this is where it belongs. Rate-limited on the collector's own
		-- liveness clock, since finding out is a pgrep.
		if now >= M._rrm_collector_next then
			M._rrm_collector_next = now + M.RRM_COLLECTOR_CHECK_INTERVAL
			M._reap_collector(rrm)
			if M._assoc_installed then
				pcall(M._assoctrack.teardown)
				M._assoc_installed = false
			end
		end
		return false
	end

	-- Once a minute, not every heartbeat -- see RRM_COLLECTOR_CHECK_INTERVAL.
	if now >= M._rrm_collector_next then
		M._rrm_collector_next = now + M.RRM_COLLECTOR_CHECK_INTERVAL
		-- The table first: the collector's on_auth hook writes into it.
		if assoc_on then
			local ok_t, inst = pcall(M._assoctrack.ensure_table)
			M._assoc_installed = (ok_t and inst) or M._assoc_installed
		elseif M._assoc_installed then
			pcall(M._assoctrack.teardown)
			M._assoc_installed = false
		end
		-- The `ubus subscribe` half serves enrichment and connection tracking
		-- only: the radar event comes off the control socket, so a DFS-only
		-- site pays for the monitors and not for the subscriber.
		if rrm_on or assoc_on then
			pcall(rrm.collector_ensure,
				assoc_on and {on_auth = M._assoctrack.forget_shell("m"), fdb = true} or nil)
			-- A collector is wanted again, so whatever the latch learned about
			-- there not being one no longer holds.
			M._collector_reaped = false
		else
			-- DFS only: no subscriber is wanted, and one left over from a run
			-- with enrichment on is a detached child that would append to the
			-- event file forever. collector_stop also takes the monitors and
			-- the file with it, so it runs before monitors_ensure below.
			M._reap_collector(rrm)
		end
		-- The control-socket monitors serve the 802.11k enrichment and the
		-- DFS radar event: connection tracking reads the ubus lines alone.
		-- M._dfs_radio is what build_json saw on the last cycle -- one cycle
		-- stale, which costs nothing on a check that runs every
		-- RRM_COLLECTOR_CHECK_INTERVAL.
		if rrm_on or dfs_on then
			if rrm.monitors_ensure then pcall(rrm.monitors_ensure) end
		elseif rrm.monitors_stop then
			pcall(rrm.monitors_stop)
		end
	end

	-- The file can only be emptied once, so one drain feeds both consumers.
	-- A quiet event file is the common case, so its size is checked before
	-- draining, the way _roam_poll already does between heartbeats.
	local blob
	if rrm.drain and M._events_pending(rrm) then
		local ok_d, b = pcall(rrm.drain)
		if ok_d then blob = b end
	end
	local evs
	if assoc_on then
		local ok_a, res = pcall(M._assoc_poll, blob)
		if ok_a then evs = res
		else io.stderr:write("inform: assoctrack: " .. tostring(res) .. "\n") end
	end
	-- Before the rrm_on return: a radar hit is reported whether or not 802.11k
	-- enrichment is on, and the monitors that produce it run on the DFS gate.
	-- `evs` is _assoc_poll's walk over these same lines, when it ran.
	if blob and blob ~= "" then pcall(M._dfs_poll, blob, evs) end
	if not rrm_on then return true end
	-- Lines _idle drained since the last heartbeat were ingested there; the
	-- beacon reports among them are still the harvest's.
	if M._pre_blob then
		local chunks = M._pre_blob
		chunks[#chunks + 1] = blob or ""
		blob, M._pre_blob = table.concat(chunks), nil
	end

	-- `blob or ""`, never nil: harvest drains the file itself when handed
	-- nothing, which would undo the size gate above.
	local ok, fresh, reporters = pcall(rrm.harvest, blob or "")
	if ok then
		for _, n in ipairs(fresh or {}) do
			-- Keyed by BSSID so a neighbour two clients both saw is carried
			-- once, at whichever sighting is freshest.
			local prev = M._rrm_cache[n.bssid]
			if not prev or n.seen_at >= prev.seen_at then
				-- hostapd emits each report twice: on the control socket with
				-- the neighbour's beacon body, then over ubus without. The two
				-- reach the event file through different processes and land in
				-- different drains often enough (live, 2026-10-13: every row of
				-- one office report went out unnamed, on the 80 MHz centre
				-- channel 42 at 20 MHz). A bodiless copy keeps what the body
				-- proved about the same BSS instead of erasing it.
				if prev and prev.body and not n.body and prev.band == n.band then
					n.essid, n.security, n.bw = prev.essid, prev.security, prev.bw
					n.channel, n.body = prev.channel, true
				end
				M._rrm_cache[n.bssid] = n
			end
		end
		-- A station that reported anything at all is one that answers.
		for mac in pairs(type(reporters) == "table" and reporters or {}) do
			M._rrm_asked[mac] = nil
		end
	end

	-- n.seen_at comes from rrmscan's own _now, so a test stubbing one clock
	-- must stub the other.
	local live = {}
	for bssid, n in pairs(M._rrm_cache) do
		if now - n.seen_at < RRM_MAX_AGE then
			live[#live + 1] = n
		else
			M._rrm_cache[bssid] = nil
		end
	end
	table.sort(live, function(a, b) return a.bssid < b.bssid end)
	M._rrm_neighbours = live

	if M._not_due(M._rrm_next_request, now, math.max(
		tonumber(cfg.config.rrm_request_interval) or 0, M.RRM_REQUEST_INTERVAL)) then return true end
	M._rrm_next_request = now +
		(tonumber(cfg.config.rrm_request_interval) or M.RRM_REQUEST_INTERVAL)

	-- Round-robin across every capable station on every BSS, one per
	-- interval. Asking them all at once would take every 802.11k-capable
	-- client in the house off-channel simultaneously.
	local cands = {}
	local ok_o, objs = pcall(rrm.hostapd_objects)
	for _, obj in ipairs(ok_o and objs or {}) do
		local ifname = obj:match("^hostapd%.(.+)$")
		local ok_s, stas = pcall(rrm.capable_stations, ifname)
		for _, sta in ipairs(ok_s and stas or {}) do
			local key   = tostring(sta):lower()
			local asked = M._rrm_asked[key]
			local benched = asked and asked.n >= M.RRM_MAX_UNANSWERED
				and (now - asked.at) < M.RRM_BENCH_SECONDS
			if asked and asked.n >= M.RRM_MAX_UNANSWERED and not benched then
				-- Bench over: one more try, from a clean count.
				M._rrm_asked[key] = nil
				benched = false
			end
			if not benched then
				cands[#cands + 1] = {ifname = ifname, sta = sta}
			end
		end
	end
	if #cands == 0 then return true end
	M._rrm_rr = (M._rrm_rr % #cands) + 1
	local c = cands[M._rrm_rr]
	local key = tostring(c.sta):lower()
	local asked = M._rrm_asked[key] or {n = 0}
	asked.n, asked.at = asked.n + 1, now
	M._rrm_asked[key] = asked
	if asked.n == M.RRM_MAX_UNANSWERED then
		io.stderr:write(string.format(
			"openuf: rrm: %s on %s advertises beacon measurement but has answered none of %d "
			.. "requests -- not asking again for %d h\n",
			c.sta, c.ifname, asked.n - 1, math.floor(M.RRM_BENCH_SECONDS / 3600)))
	end
	-- The operating class has to be one the CLIENT can measure. Upstream asks
	-- every station for class 115 (5 GHz U-NII-1) and relies on dual-band
	-- clients answering for 2.4 GHz as well -- which they do -- but a
	-- 2.4 GHz-only client answers a 5 GHz class with report mode 0x02,
	-- "incapable", and an all-zero BSSID. Seen live on AP2 the first time
	-- this ran: the one 802.11k-capable station was a 1x1 HT IoT device on
	-- 2.4 GHz, and its only report was that refusal. So a station on a
	-- 2.4 GHz BSS is asked for class 81 (2.4 GHz, channels 1-13), one on
	-- 5 GHz for 115 as before; the band comes from the BSS's live channel.
	local op_class = 115
	local ok_c, caps = pcall(M._sysinfo.radio_caps, c.ifname)
	if ok_c and type(caps) == "table" and caps.channel and caps.channel <= 14 then
		op_class = 81
	end
	pcall(rrm.request, c.ifname, c.sta, {op_class = op_class})
	return true
end

-- Where the loop leaves its heartbeat for the outside world: a flat key=value
-- file rewritten (atomically) after every completed cycle. It is what
-- update.sh waits on to decide whether a freshly installed daemon is alive and
-- talking to the controller before it commits to the new version -- and what
-- tools/check.sh shows an operator. tmpfs, so a reboot starts it clean.
M.STATUS_FILE = "/tmp/openuf-status"

-- The build stamp dist.sh / install.sh leave next to the code, read once.
M._build = nil
local function build_stamp()
	if M._build == nil then
		local s = M._read_file("BUILD") or M._read_file("openuf/BUILD")
		M._build = s and s:match("^%s*(.-)%s*$") or "unknown"
	end
	return M._build
end

-- The outcome of a config push (a setparam carrying system_cfg). Any stage
-- failed: st.push_fail is now and st.push_fail_stages names them, plus one
-- log line, because nothing heals it on its own (controller 10.6.106 does
-- not push again, and a restart does not rerun the switch or system
-- stages). In state.json, saved by the setparam branch, so a restart keeps
-- showing it. A full push (one carrying the WiFi tables, which reruns every
-- stage) that applied replaces the record; a partial one only adds to it,
-- since the stages it skipped are still as they were. push_ok (the last
-- fully applied push) is in memory only. "Applied" means no stage raised:
-- a stage that refuses without raising (switchvlan on a board with no port
-- map) is in the log only.
M.PUSH_HINT = "Force Provision this device in the controller (or change one of its settings)"
function M._note_push(st, failed, full, quiet)
	M._push_open = false
	if type(st) ~= "table" then return end
	local names = {}
	if not full then
		for n in tostring(st.push_fail_stages or ""):gmatch("[^,]+") do names[#names + 1] = n end
	end
	for _, n in ipairs(type(failed) == "table" and failed or {}) do
		local dup = false
		for _, m in ipairs(names) do if m == n then dup = true end end
		if not dup then names[#names + 1] = n end
	end
	if #names == 0 then
		M._status.push_ok = M._time()
		st.push_fail_stages, st.push_fail = nil, nil
		return
	end
	if type(failed) == "table" and #failed > 0 then st.push_fail = M._time() end
	st.push_fail_stages = table.concat(names, ",")
	if type(failed) == "table" and #failed > 0 and not quiet then
		io.stderr:write("inform: config push applied in part, not applied: " .. st.push_fail_stages
			.. " -- " .. M.PUSH_HINT .. " to send it again\n")
	end
end

-- Commit-confirm for the management address (audit #10). A push that
-- really changes it (mode, address, netmask or gateway; not the
-- steady-state repeat of the same values) first saves the old ip_mode and
-- static_* fields plus a kernel snapshot of the port in st.ip_rollback, on
-- disk before the change, so a reboot inside the window still rolls back.
-- Any controller reply after that (an HTTP error too: the controller was
-- reached) confirms it. With no reply IP_ROLLBACK_FAILS times in a row and
-- IP_ROLLBACK_SECS since the change, the old address is put back. The
-- cfgversion stays recorded, so the controller does not push the bad
-- address again by itself; a later full push carries it again and costs
-- one more window. Known limits: snapshot and apply act on lan_cpueth, so
-- on a board whose address sits on the bridge master the old address can
-- confirm the new one (apply_static's own limit); a rollback to a leased
-- address leaves renewal to the DHCP client that was already running.
M.IP_ROLLBACK_FAILS = 3
M.IP_ROLLBACK_SECS = 90
function M._arm_ip_rollback(st, iface, dhcp, ip, netmask, gateway)
	local change
	if dhcp then
		change = st.ip_mode == "static"
	else
		change = st.ip_mode ~= "static" or st.static_ip ~= ip
			or (st.static_netmask or "") ~= (netmask or "")
			or (st.static_gateway or "") ~= (gateway or "")
	end
	if not change then return end
	local snap = M._netconfig.snapshot and M._netconfig.snapshot(iface)
	if type(snap) ~= "table" then return end
	st.ip_rollback = {mode = st.ip_mode, ip = st.static_ip, mask = st.static_netmask,
		gw = st.static_gateway, dns = st.static_dns, at = M._time(), snap = snap}
	M._state.save(st)
end

-- At startup: the window starts again. Failures before the reboot, and the
-- arm time on a clock that may have reset, say nothing about this boot,
-- where the first POSTs can fail only because the link is still coming up.
function M._ip_rollback_boot(st)
	local rb = st.ip_rollback
	if type(rb) == "table" then rb.fails, rb.at = 0, M._time() end
end

-- Called once per inform POST while st.ip_rollback is set. reached: the
-- controller answered (any HTTP status).
function M._ip_rollback_check(st, cfg, reached)
	local rb = st.ip_rollback
	if type(rb) ~= "table" or type(rb.snap) ~= "table" then
		st.ip_rollback = nil
		pcall(M._state.save, st)
		return
	end
	if reached then
		st.ip_rollback = nil
		io.stderr:write("inform: new management address confirmed by the controller\n")
		pcall(M._state.save, st)
		return
	end
	rb.fails = (tonumber(rb.fails) or 0) + 1
	local since = M._time() - (tonumber(rb.at) or 0)
	-- since < 0: the clock went back (a reboot without an RTC); count only.
	if rb.fails < M.IP_ROLLBACK_FAILS or (since >= 0 and since < M.IP_ROLLBACK_SECS) then
		return
	end
	st.ip_rollback = nil
	local iface = cfg and cfg.net and cfg.net.lan_cpueth
	if not M._netconfig.restore(iface, rb.snap) then
		-- Nothing was changed on the port, so the record of it stays too.
		io.stderr:write("inform: ip rollback record unusable, dropped\n")
		pcall(M._state.save, st)
		return
	end
	local function s(v) return type(v) == "string" and v or nil end
	st.ip_mode, st.static_ip, st.static_netmask, st.static_gateway =
		s(rb.mode), s(rb.ip), s(rb.mask), s(rb.gw)
	st.static_dns = type(rb.dns) == "table" and rb.dns or nil
	local first = type(rb.snap.addrs) == "table" and rb.snap.addrs[1]
	st.ip = type(first) == "string" and first:match("^([%d%.]+)/") or st.ip
	io.stderr:write("inform: controller not reached after a management address change; "
		.. "old management address put back -- check IP Settings in the controller\n")
	M._note_push(st, {"ip_rollback"}, false, true)
	pcall(M._state.save, st)
	pcall(M._write_status, st, {})
end

-- Replay of a partly failed config push (audit #4 option B). A push with
-- failed stages keeps its system_cfg here, in this module's memory only:
-- it holds the PSKs, so never in st or on flash, and a restart drops it
-- (the push record _note_push saved stays). After REPLAY_DELAYS seconds
-- (each counted from the previous try) handle_response runs it again with
-- M._replay_only naming the stages still failing, so the stages that went
-- through are not redone: a replay without the WiFi stage runs no `wifi
-- reload`. Any later push replaces the copy; a replay with nothing left
-- failing drops it; after the last delay it gives up and the record stays.
-- Runs only after an inform the controller answered.
M.REPLAY_DELAYS = {30, 120, 600}
local replay
function M._push_replay_arm(sys_raw, failed, now, cfgversion)
	replay = nil
	if type(sys_raw) ~= "string" or type(failed) ~= "table" or #failed == 0 then return end
	local only = {}
	for _, n in ipairs(failed) do only[n] = true end
	replay = {sys = sys_raw, only = only, cfgversion = cfgversion, n = 0,
		due = now + M.REPLAY_DELAYS[1]}
end

function M._push_replay_tick(st, cfg, now)
	local r = replay
	if not r or now < r.due then return false end
	r.n = r.n + 1
	M._replay_only, M._replay_failed = r.only, nil
	local ok, err = pcall(M.handle_response, cjson.encode({_type = "setparam",
		system_cfg = r.sys, cfgversion = r.cfgversion}), st, cfg)
	local still = M._replay_failed
	M._replay_only, M._replay_failed = nil, nil
	if not ok then
		io.stderr:write("inform: push replay failed: " .. tostring(err) .. "\n")
		if M._push_open then
			pcall(M._note_push, st, {"aborted"}, false)
			pcall(M._state.save, st)
		end
	elseif type(still) == "table" and #still == 0 then
		replay = nil
		io.stderr:write("inform: config push replayed, every stage applied\n")
		return true
	elseif type(still) == "table" then
		r.only = {}
		for _, n in ipairs(still) do r.only[n] = true end
	end
	local d = M.REPLAY_DELAYS[r.n + 1]
	if d then
		r.due = now + d
	else
		replay = nil
		io.stderr:write("inform: config push replay gave up after " .. r.n .. " tries -- "
			.. M.PUSH_HINT .. "\n")
	end
	return true
end

-- fields: {last_ok = epoch, last_type = "noop"} on success, or
-- {last_fail = epoch, last_fail_msg = "..."} on a transport failure. The
-- other side's last value is carried forward so the file always shows both
-- the last success and the last failure.
M._status = {}
function M._write_status(st, fields)
	for k, v in pairs(fields) do M._status[k] = v end
	local s = M._status
	local lines = {
		"last_ok="       .. tostring(s.last_ok or 0),
		"last_type="     .. tostring(s.last_type or ""),
		"last_fail="     .. tostring(s.last_fail or 0),
		"last_fail_msg=" .. tostring(s.last_fail_msg or ""):gsub("[\r\n]", " "),
		"adopted="       .. tostring(st and st.adopted or false),
		"cfgversion="    .. tostring(st and st.cfgversion or ""),
		"mac="           .. tostring(st and st.mac or ""),
		"inform_url="    .. tostring(st and st.inform_url or ""),
		"build="         .. build_stamp(),
		"push_ok="       .. tostring(s.push_ok or 0),
		"push_fail="     .. tostring(st and st.push_fail or 0),
		"push_fail_stages=" .. (tostring(st and st.push_fail_stages or ""):gsub("[\r\n]", " ")),
	}
	local tmp = M.STATUS_FILE .. ".tmp"
	local f = io.open(tmp, "w")
	if not f then return false end
	f:write(table.concat(lines, "\n"), "\n")
	f:close()
	return os.rename(tmp, M.STATUS_FILE) and true or false
end

-- Send queued STA_ASSOC_TRACKER notifs, each as its own inform POST:
-- inform_as_notif/notif_reason/notif_payload next to the device identity.
-- The controller answers a bare noop (no interval) from its notif branch,
-- before any stats or config handling -- so the reply is deliberately not
-- fed to handle_response, which would read the missing interval as "back to
-- the default cadence". A failed POST puts the rest back for next cycle.
-- (_post_notif, above, is the other notif path: a device event such as a
-- finished RF sweep, sent once with the whole heartbeat payload.)
--
-- A payload the controller itself refuses (an HTTP 4xx, or one that cannot
-- be built) is tried NOTIF_MAX_TRIES times and then dropped and logged, so
-- one permanent refusal cannot hold every later event back. A transport
-- failure (no answer at all) is not counted: that is the link, not the event.
M.NOTIF_MAX_TRIES = 3
M._notif_tries = setmetatable({}, {__mode = "k"})
local function post_notifs(st, batch, requeue)
	local sent = 0
	for i, p in ipairs(batch) do
		local body = {}
		for k, v in pairs(M._notif_identity) do body[k] = v end
		body.time            = M._time()
		body.inform_as_notif = true
		body.notif_reason    = "event"
		body.notif_payload   = p
		local ok_p, pkt = pcall(M.build_packet, cjson.encode(body), st)
		local resp, err
		if ok_p then resp, err = M.http_post(st.inform_url, pkt) else err = tostring(pkt) end
		if resp then
			M._notif_tries[p] = nil
			sent = sent + 1
		else
			local refused = not ok_p or tostring(err):match("^HTTP 4%d%d") ~= nil
			local tries = refused and (M._notif_tries[p] or 0) + 1 or 0
			if refused and tries >= M.NOTIF_MAX_TRIES then
				M._notif_tries[p] = nil
				io.stderr:write(("inform: notif %s refused %d times (%s) -- dropped\n")
					:format(tostring(type(p) == "table" and p.event_string or "station event"),
						tries, tostring(err)))
			else
				if refused then M._notif_tries[p] = tries end
				local rest = {}
				for j = i, #batch do rest[#rest + 1] = batch[j] end
				requeue(rest)
				return sent, false
			end
		end
	end
	return sent, true
end

-- Device events, as opposed to the per-station notifs above: same envelope
-- (notif_reason "event"), but the payload is an `event_string` the
-- controller's own event registry dispatches on, and the device identity is
-- all the rest it needs. The controller logs the event under its site and
-- raises the matching alert.
--
-- Of the eleven EVT_AP_* strings 10.6.106 has a handler for, exactly one is
-- sent by the AP: EVT_AP_RadarDetected. The other ten (ChannelChanged,
-- DetectRogueAP, Isolated, PossibleInterference, AcsTriggerComplete,
-- QuickScanEvent, LocationEvent, AfcEvent, RestartProc, RestartedUnknown)
-- appear nowhere in U7LR 6.8.2's binaries: the controller raises them itself
-- from what it already knows, so there is nothing for a device to send.
-- Conversely EVT_AP_WirelessEvent and EVT_AP_Notification, which 6.8.2 does
-- emit, have no handler in 10.6.106 at all.
M.MAX_EVENTS = 16
M._event_queue = {}

-- Two BSSes on the same radio both see the same radar hit, and hostapd prints
-- the event on each BSS's control socket -- so the same detection arrives
-- once per BSS. Collapsed on (channel, second): the controller would
-- otherwise log one alert per VAP for one radar.
M.EVENT_DEDUP_S = 5
M._event_seen = {}

function M.queue_event(p)
	if type(p) ~= "table" or not p.event_string then return false end
	if p.dedup_key then
		local now, key = M._time(), p.dedup_key
		local last = M._event_seen[key]
		if last and now - last < M.EVENT_DEDUP_S then return false end
		M._event_seen[key] = now
		for k, v in pairs(M._event_seen) do
			if now - v > M.EVENT_DEDUP_S * 4 then M._event_seen[k] = nil end
		end
		p.dedup_key = nil
	end
	if #M._event_queue >= M.MAX_EVENTS then return false end
	M._event_queue[#M._event_queue + 1] = p
	return true
end

-- The radar detections in one drained collector blob, queued as the
-- controller's own event. `vap` is the interface hostapd reported it on,
-- which is what 6.8.2 sends beside channel and freq; the handler reads
-- channel (as a string) and freq (as a number) and ignores the event if
-- either is missing.
--
-- `evs` is assoctrack.parse_events' output over the same blob, when connection
-- tracking has already walked it: its radar records are turned into the same
-- {t, ifname, freq, channel} rows by rrmscan.radar_of, so the blob is walked
-- once per drain rather than once per consumer. Without it (DFS only, nothing
-- else reading the file) parse_dfs does the walk itself.
function M._dfs_poll(blob, evs)
	local rrm = M._rrmscan
	if not (rrm and rrm.parse_dfs) then return 0 end
	local hits
	if evs then
		hits = {}
		for _, e in ipairs(evs) do
			if e.ev == "radar" then
				local d = rrm.radar_of(e.t, e.ifname, e.freq)
				if d then hits[#hits + 1] = d end
			end
		end
	else
		hits = rrm.parse_dfs(blob)
	end
	local n = 0
	for _, d in ipairs(hits) do
		if M.queue_event{
			event_string = "EVT_AP_RadarDetected",
			channel      = tostring(d.channel),
			freq         = d.freq,
			vap          = d.ifname,
			dedup_key    = "radar/" .. tostring(d.channel),
		} then
			n = n + 1
			-- Worth a line of its own: a radar hit takes the radio off that
			-- channel for 30 minutes, and this is the only record openUF
			-- leaves of why.
			io.stderr:write(string.format(
				"inform: DFS radar detected on channel %d (%d MHz) on %s"
				.. " -- reported to the controller\n",
				d.channel, d.freq, tostring(d.ifname)))
		end
	end
	return n
end

local function take_events(n)
	local out = {}
	for i = 1, math.min(n, #M._event_queue) do out[i] = M._event_queue[i] end
	for _ = 1, #out do table.remove(M._event_queue, 1) end
	return out
end

local function requeue_events(list)
	for i = #list, 1, -1 do table.insert(M._event_queue, 1, list[i]) end
end

-- Device events ride no capability: unlike the station notifs they are not
-- gated on notif-assoc-stat, since the controller asked for nothing and the
-- event is the AP telling it something it has no other way to learn.
function M._send_events(st)
	if not (st and st.adopted) or not M._notif_identity then return 0 end
	if #M._event_queue == 0 then return 0 end
	local n = post_notifs(st, take_events(M.MAX_EVENTS), requeue_events)
	return n
end

-- Roam reports first: they are the ones a delay spoils.
function M._send_notifs(st)
	local at = M._assoctrack
	if not at or not (st and st.adopted) or not M._notif_identity then return 0 end
	local n_r, ok = post_notifs(st, at.take_roams(at.MAX_ROAMS), at.requeue_roams)
	if not ok then return n_r end
	return n_r + post_notifs(st, at.take(M.NOTIFS_PER_CYCLE), at.requeue)
end

-- _idle's look at the collector between heartbeats: anything new is ingested
-- now and a roam report it produced is sent now. The size check keeps a
-- quiet file from costing more than an open.
function M._roam_poll()
	local rrm, at, st = M._rrmscan, M._assoctrack, M._roam_st
	if not (rrm and at and rrm.drain) then return end
	if not M._events_pending(rrm) then return end
	local blob = rrm.drain()
	if not blob or blob == "" then return end
	if M._roam_keep then
		local chunks = M._pre_blob or {}
		chunks[#chunks + 1] = blob
		M._pre_blob = chunks
	end
	local evs = at.parse_events(blob)
	at.ingest(evs)
	at.roam_ingest(evs, M._vap_by_ifname)
	-- This drain is the only one these lines get, so the radar events in it
	-- are queued here too; they go out with the next heartbeat. Off the walk
	-- parse_events just did, not a second one over the same blob.
	pcall(M._dfs_poll, blob, evs)
	-- Only the roam reports: the funnel's keep the heartbeat's cadence.
	if #at._roam_queue > 0 and st and st.adopted and M._notif_identity then
		post_notifs(st, at.take_roams(at.MAX_ROAMS), at.requeue_roams)
	end
end

-- One heartbeat: build, send, dispatch. Returns the number of seconds the
-- caller should wait before the next one -- 0 means "again, now", the
-- config-applied / command-executed case where a real AP re-informs at once.
-- ctx carries the loop's own state (interval, backoff, last_mtime,
-- last_scan) so run() is nothing but `while true do wait(_tick()) end` and
-- the error boundaries and the backoff can be tested without a socket.
--
-- Every stage is pcall-wrapped, and that is the point of the split.
-- build_json shells out to a dozen tools and does arithmetic on their
-- output; one nil in one field once took the whole daemon down (`nil +
-- noise`, from a radio with the minrssi flag set and no threshold), and
-- procd's respawn turned that into a crash loop every five seconds that
-- reported no statistics and logged nothing beyond the traceback. A bad
-- cycle now costs one heartbeat and one log line, and the next cycle gets
-- another go.
M._logged_pending = false

function M._tick(st, cfg, ufhw, ctx)
	-- base_interval is the device's own cadence; interval is what the loop
	-- actually waits, which the controller's noop may have moved.
	ctx.base_interval = ctx.base_interval or ctx.interval or 10
	ctx.interval = ctx.interval or ctx.base_interval
	ctx.backoff  = ctx.backoff  or ctx.interval
	local dump_tx = cfg and cfg.config and cfg.config.debug_dump_requests

	-- One ucihelper lookup pass from here to the payload: the resyncs below
	-- (three of them each asked netifd for the VAP list on the same tick
	-- once a minute), the WLAN schedule check and build_json share one
	-- `ubus call network.wireless status` and one read of the wireless
	-- config. Ended and reopened, never joined: a pass a throw left open
	-- holds the last cycle's answers. A `wifi reload` inside it (a Forget)
	-- drops what it held. Closed after build_json, below, before
	-- handle_response can change the config.
	local ufuci = M._ucihelper
	if ufuci and ufuci.begin_pass and ufuci.end_pass then
		ufuci.end_pass()
		ufuci.begin_pass()
	end
	ctx.last_mtime = M._reload_if_changed(st, cfg, ctx.last_mtime)
	-- The STUN client: a Binding Request every stun.INTERVAL, before the
	-- inform so the reply's mapped address rides out on it.
	pcall(M._stun_tick, st)
	M._maybe_scan_neighbours(cfg, ctx)
	-- One chunk of whatever sweep is queued (a command's, or the 11k-scan's),
	-- before build_json so this inform carries what it found.
	pcall(M._scan_job_tick)
	-- Before build_json, so anything a client reported since the last cycle
	-- rides out on THIS inform rather than waiting for the next.
	pcall(M._rrm_tick, cfg, st)
	-- The controller's nightly dfs-reset (syswrapper.sh dfs-reset): put a
	-- radio a radar hit moved back on its configured DFS channel.
	pcall(M._maybe_service_dfs_reset, cfg)
	-- Before the resyncs: opens their gates when the VAP set changed.
	pcall(M._vap_watch, M._time())
	pcall(M._l2guard_resync, st)
	pcall(M._bcfilt_resync)
	pcall(M._backhaul_tick, st, cfg)
	pcall(M._uplinkmon_resync, st, cfg)
	pcall(M._meshvlan_resync, st, cfg)
	pcall(M._guest_resync, st)
	pcall(M._guest_wg_resync, st)
	pcall(M._hairpin_resync)
	pcall(M._usteer_filter_resync)
	pcall(M._block_resync, st)
	pcall(M._sched_resync, st)
	pcall(M._rrbguard_tick)
	-- The address this inform reports, read now rather than at startup (see
	-- _refresh_net_info: a DHCP lease that arrived after the daemon did).
	pcall(M._refresh_net_info, st, cfg)

	local ok_b, json_str = pcall(M.build_json, st, cfg, ufhw)
	-- The cycle's ucihelper pass, opened above, ends here whether or not
	-- build_json returned: a pass left open would feed handle_response's own
	-- lookups pre-reload interface names. build_json closes its sysinfo pass
	-- on return; an error skips that, so it is closed here too.
	if ufuci and ufuci.end_pass then pcall(ufuci.end_pass) end
	if M._sysinfo and M._sysinfo.end_pass then pcall(M._sysinfo.end_pass) end
	if not ok_b then
		io.stderr:write("inform: build_json failed: " .. tostring(json_str) .. "\n")
		pcall(M._write_status, st, {last_fail = M._time(),
			last_fail_msg = "build_json failed: " .. tostring(json_str)})
		return ctx.interval
	end
	-- build_json cleared a stale upgrade mark (see reported_uptime).
	if M._uptime_mark_cleared then
		M._uptime_mark_cleared = false
		pcall(M._state.save, st)
	end
	-- On the stations build_json just listed.
	local ok_sh, err_sh = pcall(M._shaper_resync, st)
	if not ok_sh then io.stderr:write("inform: shaper: " .. tostring(err_sh) .. "\n") end
	if dump_tx then M._debug_append(cfg, "TX", json_str) end

	local ok_p, pkt = pcall(M.build_packet, json_str, st)  -- use_gcm read from st.use_gcm
	if not ok_p then
		io.stderr:write("inform: build_packet failed: " .. tostring(pkt) .. "\n")
		pcall(M._write_status, st, {last_fail = M._time(),
			last_fail_msg = "build_packet failed: " .. tostring(pkt)})
		return ctx.interval
	end

	local body, err = M.http_post(st.inform_url, pkt)
	if st.ip_rollback ~= nil then
		local reached = body ~= nil or (type(err) == "string" and err:match("^HTTP %d") ~= nil)
		local ok_rb, err_rb = pcall(M._ip_rollback_check, st, cfg, reached)
		if not ok_rb then io.stderr:write("inform: ip rollback: " .. tostring(err_rb) .. "\n") end
	end
	if not body then
		if dump_tx then M._debug_append(cfg, "ERR", tostring(err)) end
		pcall(M._write_status, st, {last_fail = M._time(), last_fail_msg = tostring(err)})
		-- A controller answers HTTP 404 to every inform from a device it has
		-- not adopted, until someone clicks Adopt. That is its normal answer,
		-- not a fault: backing off to 60 s would leave the first inform after
		-- the click, the one that picks up the new key, up to a minute away.
		-- The failure is still written above: the LuCI Setup page reads the
		-- 404 in last_fail_msg as "pending adoption". (jonasevcik dcfe0df)
		if not st.adopted and err == "HTTP 404" then
			if not M._logged_pending then
				io.stderr:write("inform: pending adoption (HTTP 404 until adopted in the controller)\n")
				M._logged_pending = true
			end
			ctx.interval = ctx.base_interval
			ctx.backoff  = ctx.interval
			return ctx.interval
		end
		io.stderr:write("inform: POST failed: " .. tostring(err) .. "\n")
		M._warn_http_400(err, st, cfg)
		if M._guestportal then pcall(M._guest_selfrun, st, false) end
		-- Doubles from the CURRENT cadence, capped at 60 s -- or at the
		-- controller's own interval when that is longer, since a failure
		-- must never make the device poll faster than it was asked to.
		local cap = math.max(60, ctx.interval)
		-- HTTP 503 is the controller shedding inform load ("Server is busy"
		-- on 10.6): the wait goes straight to the cap rather than doubling
		-- through 20 s and 40 s of more requests.
		if err == "HTTP 503" then
			ctx.backoff = cap
			return ctx.backoff
		end
		ctx.backoff = math.min(math.max(ctx.backoff, ctx.interval) * 2, cap)
		return ctx.backoff
	end
	ctx.backoff = ctx.interval
	M._warned_400 = false
	M._logged_pending = false
	if M._guestportal then pcall(M._guest_selfrun, st, true) end

	local parse_ok, json_body = pcall(M.parse_packet, body, st)
	if not parse_ok then
		io.stderr:write("inform: parse error: " .. tostring(json_body) .. "\n")
		pcall(M._write_status, st, {last_fail = M._time(), last_fail_msg = "parse error"})
		return ctx.interval
	end
	local rtype = tostring(json_body):match('"_type"%s*:%s*"([%w_%-]+)"') or "?"
	local ok_h, applied = pcall(M.handle_response, json_body, st, cfg)
	-- Whatever handle_response recorded on the way -- including on the way
	-- to raising -- is written now if the ledger's own policy says so.
	if M._unhandled then pcall(M._unhandled.flush) end
	if not ok_h then
		io.stderr:write("inform: handle_response failed: " .. tostring(applied) .. "\n")
		-- A config push that raised outside its stages' pcalls: some of it
		-- ran, the rest did not, and its state.save was skipped. Record and
		-- save it rather than keep showing the last push as applied (a noop
		-- run saves nothing, and an outside write reloads st from disk).
		if M._push_open then
			pcall(M._note_push, st, {"aborted"}, false)
			pcall(M._state.save, st)
			pcall(M._write_status, st, {})
		end
		return ctx.interval
	end
	-- After the state inform, never instead of it: the controller has just
	-- heard from this AP, and a notif from a device it considers lost is
	-- discarded anyway.
	if M._assoc_enabled(st, cfg) then pcall(M._send_notifs, st) end
	pcall(M._send_events, st)
	-- The controller's requested cadence, or the device's own when the last
	-- noop named none. The backoff was reset to the old cadence above, before
	-- this response could move it; follow it here too, or the first failure
	-- after a drop would double from the stale, longer value.
	ctx.interval = M._controller_interval or ctx.base_interval
	pcall(M._write_status, st, {last_ok = M._time(), last_type = rtype})
	-- After the answer and outside the cycle's ucihelper pass, like a push.
	local ok_rp, err_rp = pcall(M._push_replay_tick, st, cfg, M._time())
	if not ok_rp then io.stderr:write("inform: push replay: " .. tostring(err_rp) .. "\n") end
	-- A device event the last command left behind (a finished sweep) goes
	-- out now, as its own notification inform, after the heartbeat that
	-- carried the result it dates.
	if M._pending_notif then pcall(M._post_notif, st, cfg, json_str) end
	if applied then
		-- The push ran `wifi reload`, which killed the RRM collector's
		-- subscription; check it again on the very next heartbeat rather
		-- than waiting out RRM_COLLECTOR_CHECK_INTERVAL.
		M._rrm_collector_next = 0
		return 0
	end
	return ctx.interval
end

-- Start the inform heartbeat loop (blocks forever).
-- cfg, ufhw: passed through to build_json()
function M.run(cfg, ufhw)
	local st = state.load()
	-- The ledger of what the controller sent that nothing here acted on
	-- (unhandled.lua), loaded before the first response so counts and
	-- first_seen carry across restarts. conf.lua's unhandled_file names the
	-- file; false keeps it in memory only. pcall'd: a full overlay must not
	-- stop the daemon.
	if M._unhandled then
		local uf = cfg and cfg.config and cfg.config.unhandled_file
		if uf ~= nil then M._unhandled._file = uf end
		local ok_u, err_u = pcall(M._unhandled.load)
		if not ok_u then
			io.stderr:write("inform: could not load the unhandled ledger: "
				.. tostring(err_u) .. "\n")
		end
	end
	-- The model name ("U6IW"), for the beacon's AP name when the controller
	-- pushes no device name (handle_response gets no ufhw).
	M._model = ufhw and ufhw.uap and ufhw.uap.model or M._model
	-- The MAC persisted by the previous run (state.save writes the whole
	-- table and state.load now reads it all back), before _populate_net_info
	-- overwrites it with the live one read off dev.conf.net.lan_cpueth.
	local prev_mac = st.mac
	-- A controller-pushed static address is kernel state and died with the
	-- reboot; put it back BEFORE the identity fields are read off the
	-- interface, so the very first inform reports where the device actually
	-- is. pcall'd: a malformed record must not stop the daemon.
	pcall(M._ip_rollback_boot, st)
	local ok_ip, err_ip = pcall(M._reapply_static_ip, st, cfg)
	if not ok_ip then
		io.stderr:write("inform: could not reapply static IP: " .. tostring(err_ip) .. "\n")
	end
	M._populate_net_info(st, cfg)
	M._warn_identity_change(prev_mac, st, cfg)
	M._warn_missing_uci()
	-- Identity and reported address must come off the same netdev. openUF
	-- takes the MAC from lan_cpueth and the IP from the bridge that port is
	-- enslaved to, which only agree when the two share a MAC -- true on every
	-- swconfig board, false on a DSA board whose map names a socket, where the
	-- gateway then flags an IP conflict between the AP and itself. Reconciled
	-- once, here, before the first inform carries the mismatch. pcall'd for
	-- the same reason reapply_runtime_rules is: this reaches UCI and sysfs, and
	-- a board where either is missing must still start and report statistics.
	if M._ucihelper and M._ucihelper.ensure_bridge_identity then
		local ok_id, err_id = pcall(M._ucihelper.ensure_bridge_identity, cfg)
		if not ok_id then
			io.stderr:write("inform: could not reconcile bridge identity: "
				.. tostring(err_id) .. "\n")
		elseif err_id then
			-- It changed UCI; netifd has to be told, and nothing else at
			-- startup consumes _network_dirty (apply_config's reload only runs
			-- on a setparam, which may be many minutes away or never).
			M._ucihelper._network_dirty = false
			M._sysinfo._run_cmd("/etc/init.d/network reload 2>/dev/null")
			M._populate_net_info(st, cfg)  -- the address may have moved with it
		end
	end
	M._warn_debug_overrides(cfg)
	M._sync_bootstrap_account(st.adopted, cfg and cfg.config and cfg.config.bootstrap_adopt_user)
	M._reconcile_plugins(st, cfg)
	M._migrate_legacy_rrb(st, cfg)
	-- Blocked-client nft rules are live kernel state, not persisted UCI --
	-- reapply from state.json on every fresh start (mirrors the bootstrap
	-- account reconciliation just above).
	M._firewall.reconcile(st.blocked_stas)
	-- Same category, one level out: the "Multicast and Broadcast Blocker" is an
	-- nftables ruleset, so it dies with the reboot, and has no UCI option
	-- OpenWrt itself applies. It is only ever built inside apply_config, which
	-- runs on a setparam -- and after a reboot there is no setparam: cfgversion
	-- matches on the first inform and the controller replies noop, carrying no
	-- system_cfg at all. It therefore stayed off indefinitely while the UI
	-- showed it on. Rebuilt here from the openuf_bcfilt options wlan_add stamps
	-- onto each managed section. (The WiFi Speed Limit is rebuilt by every
	-- heartbeat's _shaper_resync from openuf_ratelimit_*.)
	--
	-- pcall'd because it reaches ubus for each VAP's live netdev name: no
	-- radios, no wifi up yet, no ubus at all are ordinary outcomes on a board
	-- openUF has never provisioned, and none of them may stop the daemon.
	if M._ucihelper and M._ucihelper.reapply_runtime_rules then
		local ok_rt, err_rt = pcall(M._ucihelper.reapply_runtime_rules)
		if not ok_rt then
			io.stderr:write("inform: could not reapply the blocker rules: "
				.. tostring(err_rt) .. "\n")
		end
	end
	-- A Locate does NOT survive a restart, and must not: it is a transient
	-- "which box is it" blink, nobody is still standing in front of the AP,
	-- and unset-locate only ever arrives while someone is watching the
	-- controller. Left alone the device comes back still blinking with no
	-- snapshot of what the LED was on, and the next unset-locate -- if one
	-- ever comes -- restores nothing. Worse, a second set-locate would
	-- snapshot the blink itself as the thing to restore. Upstream observed
	-- exactly that on an AX3000T, whose radio LED stayed on the identify
	-- blink across three Locate cycles.
	if st.locating then
		-- Only when the LED is really still blinking: a device that REBOOTED
		-- mid-Locate comes back with the kernel's own default trigger already
		-- restored, and "stopping" that would write none over it.
		if M._led.locate_active(cfg and cfg.led) then
			M._led.locate_stop(cfg and cfg.led, st.locate_prev_trigger)
		end
		st.locating = false
		st.locate_prev_trigger = nil
		-- Startup: a full overlay or a missing directory must not stop the
		-- daemon here, before its first inform. The next save retries.
		local ok_sv, err_sv = pcall(M._state.save, st)
		if not ok_sv then
			io.stderr:write("inform: state not saved at startup: " .. tostring(err_sv) .. "\n")
		end
	end
	-- LED brightness is live kernel state too, not UCI -- the same reason the
	-- blocked-client rules are reapplied above. The controller pushes
	-- led_enabled once, in mgmt_cfg, and never again, so without this the
	-- Manage > LED toggle silently forgets itself on every reboot while the
	-- controller goes on believing it took. Applied AFTER the locate teardown:
	-- if both have something to say, the steady state the operator chose wins
	-- over whatever trigger the blink displaced. nil means it was never
	-- pushed, which must leave the board's own default alone.
	if st.led_enabled ~= nil then
		M._led.set_enabled(cfg and cfg.led, st.led_enabled)
	end
	M._reapply_airtime(st)
	-- Per-port byte counters are a switch-driver setting that some boards ship
	-- switched off; without it every socket reports 0 B in the Ports view.
	if M._switchvlan then pcall(M._switchvlan.enable_mib_polling, cfg) end
	-- nftables state does not survive a reboot, so the per-socket MAC tap is
	-- reinstalled here from the UCI sections that record which sockets have
	-- learning off -- the same discipline _firewall.reconcile uses for the
	-- blocklist. A tap that is not reinstalled fails silently, as an empty
	-- mac_table, which is the bug it exists to fix.
	if M._switchvlan and M._switchvlan.reconcile_mac_taps then
		pcall(M._switchvlan.reconcile_mac_taps)
	end
	-- The controller's ebtables hardening (BPDU and VLAN-tag drop on the
	-- VAPs) is nft state too. Rebuilt from state.json's record with the live
	-- VAP list, falling back to the names recorded at the last push when
	-- wireless is not answering yet at this point of the boot;
	-- _l2guard_resync corrects the list once it is.
	if M._l2guard and type(st.l2guard) == "table" then
		pcall(function()
			local names = M._l2guard_live_ifnames()
			if #names == 0 and type(st.l2guard.ifnames) == "table" then names = st.l2guard.ifnames end
			M._l2guard.reconcile(st.l2guard, names)
		end)
	end
	-- So are the mesh VLAN ports and their guard (meshvlan.lua): guard first,
	-- ports after, from state.json's record. A VLAN bridge netifd has not
	-- built yet gets its port on a later heartbeat.
	pcall(M._meshvlan_resync, st, cfg)
	-- The guest portal's tables, likewise (lab-validated only).
	if M._guestportal and type(st.guest_portal) == "table" then
		pcall(M._guest_enforce, st)
	end

	local socket = require("socket")
	local ctx = {
		interval   = 10,
		backoff    = 10,
		last_mtime = M._state_mtime(M._state._state_file),
	}
	while true do M._cycle(st, cfg, ufhw, ctx, socket) end
end

-- Injectable for tests.
M._collectgarbage = collectgarbage

-- One heartbeat, then a full collection, then the wait. Each tick builds a
-- payload, parses the controller's answer and reads most of /proc and the
-- driver's tables, then drops all of it. Left to the default pause the heap
-- doubles before a cycle runs, and the process keeps the pages it grew into.
-- Collecting here, once the garbage is all garbage, measured upstream on
-- their two boards over 30 min each (2026-10-17): the daemon's RssAnon
-- 3068 -> 2378 kB on an Archer C5, 3882 -> 3030 kB on an AX3000T, the peak
-- about 1 MB lower on both, and total CPU unchanged (the 20 ms collection
-- replaces the incremental steps the tick paid for). A shorter pause
-- (setpause 100) kept less than half that saving.
function M._cycle(st, cfg, ufhw, ctx, socket)
	local wait = M._tick(st, cfg, ufhw, ctx)
	-- A mesh switch pending or just made: the next heartbeat comes sooner
	-- than the backoff a failed inform asked for (backhaul.wait_cap), and
	-- the backoff starts over, so the controller hears from the device over
	-- its new uplink seconds after it is up.
	local bh = M._backhaul
	if bh and bh.wait_cap then
		local ok, cap = pcall(bh.wait_cap, st)
		if ok and type(cap) == "number" and wait > cap then
			wait = cap
			ctx.backoff = ctx.interval
		end
	end
	-- The uplink monitor counting failed verdicts: one every PROBE_S, not one
	-- per failed inform's backoff (uplinkmon.wait_cap). The backoff stands:
	-- the controller is no nearer for it.
	local um = M._uplinkmon
	if um and um.wait_cap then
		local ok, cap = pcall(um.wait_cap)
		if ok and type(cap) == "number" and wait > cap then wait = cap end
	end
	M._collectgarbage("collect")
	-- Another process wrote state.json (syswrapper over SSH): wake, and start
	-- the backoff over, so the next heartbeat reloads it and goes out at once.
	local function state_changed()
		local token = M._state_mtime(M._state._state_file)
		return token ~= nil and token ~= ctx.last_mtime and token ~= M._state_seen()
	end
	if wait > 0 and M._idle(socket, wait, state_changed) == true then
		ctx.backoff = ctx.interval
	end
end

-- Starts the hang watchdog (hangwatch.lua): one background sh loop that kills
-- a command this blocking loop is stuck on, since a hung iw or nft would
-- otherwise stop informs, STUN and mesh failover for good. Called from the
-- entry block only, never from run(), so the tests of run() spawn nothing.
function M._start_hangwatch()
	local hw = M._hangwatch
	local msg
	if type(hw) == "table" and type(hw.start) == "function" then
		local ok, started, why = pcall(hw.start)
		if ok and started == true then
			msg = "inform: hang watchdog started (limit " .. tostring(hw.LIMIT_S) .. " s)"
		elseif ok then
			msg = "inform: hang watchdog not started: " .. tostring(why or "refused")
		else
			msg = "inform: hang watchdog not started: " .. tostring(started)
		end
	else
		msg = "inform: hang watchdog not started: module missing"
	end
	pcall(function() io.stderr:write(msg .. "\n") end)
end
end
