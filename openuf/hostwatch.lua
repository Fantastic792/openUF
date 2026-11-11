--[[
	What openUF does on its own beside the inform loop, moved out of
	inform.lua: the controller's ebtables hardening (l2guard), its scheduled
	neighbour scan, the 802.11r socket check (rrbguard), the WiFi blackout
	schedule, the Uplink Connectivity Monitor and the STUN wake-up. They run
	on the inform module's own table, so the M._* names the tests and the
	main loop use stay where they were.
	Loaded by inform.lua with  _require_sibling("hostwatch")(M).
]]--

local cjson = require("cjson")

return function(M)
local l2guard, meshvlan, wlansched = M._l2guard, M._meshvlan, M._wlansched
-- ─── The controller's ebtables hardening (l2guard.lua) ──────────────────────

-- The live AP-mode VAP netdevs, or {} while wireless is not answering.
function M._l2guard_live_ifnames()
	local ufuci = M._ucihelper
	if not (ufuci and ufuci.ap_ifnames) then return {} end
	local ok, names = pcall(ufuci.ap_ifnames)
	return (ok and type(names) == "table") and names or {}
end

local function same_names(a, b)
	if type(a) ~= "table" or type(b) ~= "table" or #a ~= #b then return false end
	for i = 1, #a do if a[i] ~= b[i] then return false end end
	return true
end

-- A push's ebtables.* block -> st.l2guard, and the table rebuilt. A push
-- without the block (a partial one) leaves the current state alone.
function M._l2guard_apply_push(sys_raw, st)
	local eb = M._l2guard.parse(sys_raw)
	if not eb then return false end
	for _, u in ipairs(eb.unknown or {}) do
		-- The guest portal's rules are guestportal.lua's to read.
		if not (M._guestportal and M._guestportal.is_guest_rule(u)) then
			io.stderr:write("l2guard: unrecognised ebtables rule shape, not applied: "
				.. ("%q"):format(u) .. "\n")
		end
	end
	local spec = M._l2guard.spec_from(eb)
	local names = M._l2guard_live_ifnames()
	if #names == 0 and type(st.l2guard) == "table" and type(st.l2guard.ifnames) == "table" then
		names = st.l2guard.ifnames   -- wireless not answering yet: last known
	end
	spec.ifnames = names
	st.l2guard = spec
	M._l2guard.reconcile(spec, names)
	return true
end

-- Once a minute: if the live VAP list no longer matches the one the table was
-- built for (an SSID added by a push whose `wifi reload` had not finished, or
-- wireless coming up after the daemon at boot), rebuild. An empty live list
-- is "not answering", never "no VAPs": it leaves the table alone. Returns true
-- when it rebuilt.
M.L2GUARD_RESYNC_INTERVAL = 60
M._l2guard_next = 0
-- One heartbeat of the wireless-uplink policy (backhaul.lua): wired first,
-- the WDS station only while the wired uplink socket has no carrier. A no-op
-- on a device whose push carried no uplink station.
function M._backhaul_tick(st, cfg)
	if not (M._backhaul and M._backhaul.tick) then return nil end
	return M._backhaul.tick(st, cfg, M._ucihelper, M._sysinfo, M._state)
end

-- The VLANs a push's tagged SSIDs sit on, each once, in push order: the
-- switch trunks them (switchvlan) and, on a swconfig mesh, meshvlan carries
-- them over the hop. A private pre-shared key's VLAN counts the same.
function M._wireless_vlans(vap_table)
	local ufuci = M._ucihelper
	local out, seen = {}, {}
	for _, vap in ipairs(vap_table or {}) do
		local vids = (ufuci and ufuci.vap_vlan_ids) and ufuci.vap_vlan_ids(vap)
			or ((vap.vlan_enabled and vap.vlan) and {vap.vlan} or {})
		for _, vid in ipairs(vids) do
			if not seen[vid] then
				seen[vid] = true
				out[#out + 1] = vid
			end
		end
	end
	return out
end

-- The uplink socket a swconfig push should plan around. While the mesh
-- station carries the uplink, the switch's ARL has the gateway on a CPU port:
-- its frames arrive over the air and br-lan floods them into the switch.
-- Taken at its word, a push handled then would trunk the tagged SSIDs' VLANs
-- to no socket -- dead on the wire the moment the cable is back, until some
-- later push -- and would accept a port VLAN on the very socket the wire
-- returns to, stranding the device when it does. So the socket the uplink
-- policy remembers (backhaul.tick) stands in for the CPU port. Only for a
-- CPU port, which is positive evidence of the air path: a gateway learnt
-- nowhere keeps today's answer (hold the trunk, refuse every port), since a
-- stale mode must never steer a port VLAN onto the socket the cable is
-- really in. Anything else is the live answer, unchanged.
function M._mesh_uplink_phys(st, cfg, live)
	if not (st and st.backhaul_mode == "wireless") then return live end
	local remembered = tonumber(st.backhaul_wired_phys)
	local n = tonumber(live)
	if not (remembered and n) then return live end
	local vlan = cfg and cfg.vlan or {}
	if n == tonumber(vlan.cpu_lan) or n == tonumber(vlan.cpu_wan) then return remembered end
	return live
end

-- A push's answer to "which VLANs ride br-lan.<vid>" on a swconfig board
-- (meshvlan.lua): st.meshvlan, saved with the rest of the push, and the
-- kernel brought to it -- guard first, ports after; ports first, guard after
-- on the way out. Wanted only with a mesh plan and a tagged SSID; a DSA
-- board's VLAN bridges have the port by design and never get a record.
function M._meshvlan_push(st, cfg, plan, vids)
	local prev = st.meshvlan
	local rec = nil
	if plan and cfg and cfg.vlan and cfg.vlan.ports and #(vids or {}) > 0 then
		local br = M._backhaul and M._backhaul.lan_bridge
			and M._backhaul.lan_bridge(cfg, M._sysinfo) or nil
		if br then
			rec = M._meshvlan.record(br, vids)
		else
			io.stderr:write("inform: meshvlan: cannot tell which bridge is the LAN -- tagged "
				.. "SSIDs are not carried over the mesh hop\n")
		end
	end
	if rec == nil and prev == nil then return false end
	st.meshvlan = rec
	M._meshvlan.reconcile(rec, prev)
	return true
end

-- Once a heartbeat, and at startup: the guard back once a minute, any port a
-- netifd reload took away re-attached. A record on a board that is no longer
-- swconfig (the profile was changed) is torn down instead.
function M._meshvlan_resync(st, cfg)
	local rec = st and st.meshvlan
	if not (M._meshvlan and type(rec) == "table") then return false end
	if not (cfg and cfg.vlan and cfg.vlan.ports) then
		M._meshvlan.reconcile(nil, rec)
		st.meshvlan = nil
		M._state.save(st)
		return false
	end
	return M._meshvlan.resync(rec, M._time())
end

function M._l2guard_resync(st)
	local g = st and st.l2guard
	if not (M._l2guard and type(g) == "table" and (g.bpdu or g.tagdrop)) then return false end
	local now = M._time()
	if M._not_due(M._l2guard_next, now, M.L2GUARD_RESYNC_INTERVAL) then return false end
	M._l2guard_next = now + M.L2GUARD_RESYNC_INTERVAL
	local names = M._l2guard_live_ifnames()
	if #names == 0 or same_names(names, g.ifnames) then return false end
	io.stderr:write("l2guard: AP interfaces changed (" .. table.concat(names, " ")
		.. ") -- rebuilding\n")
	g.ifnames = names
	M._state.save(st)
	M._l2guard.reconcile(g, names)
	return true
end

-- Once a minute: the Multicast/Broadcast Blocker's ruleset against the live
-- VAPs (ucihelper.resync_runtime_rules), so a push whose `wifi reload` had not
-- finished when the rules were built does not leave the blocker filtering
-- nothing until the next restart. Returns true when it rebuilt.
M.BCFILT_RESYNC_INTERVAL = 60
M._bcfilt_next = 0
function M._bcfilt_resync()
	local u = M._ucihelper
	if not (u and u.resync_runtime_rules) then return false end
	local now = M._time()
	if M._not_due(M._bcfilt_next, now, M.BCFILT_RESYNC_INTERVAL) then return false end
	M._bcfilt_next = now + M.BCFILT_RESYNC_INTERVAL
	return u.resync_runtime_rules()
end

-- Once a minute, independent of the ebtables block: a force-isolated BSS
-- whose bridge port lost its hairpin flag (l2guard.reconcile_hairpin) cuts
-- its clients off from each other, and the reconfigure that causes it can
-- land at any time, not just after a push. Returns the number of flags fixed.
M.HAIRPIN_CHECK_INTERVAL = 60
M._hairpin_next = 0
function M._hairpin_resync()
	if not (M._l2guard and M._l2guard.reconcile_hairpin) then return 0 end
	local now = M._time()
	if M._not_due(M._hairpin_next, now, M.HAIRPIN_CHECK_INTERVAL) then return 0 end
	M._hairpin_next = now + M.HAIRPIN_CHECK_INTERVAL
	return M._l2guard.reconcile_hairpin()
end

-- Once a minute: keep usteer's AP-to-AP broadcasts off the VAPs
-- (usteer.reconcile_filter) while openUF runs the daemon, rebuilding only when
-- that or the VAP list changed. An empty live list while wanted is "wireless
-- not answering yet" and leaves the table alone. Returns true when it rebuilt.
M.USTEER_FILTER_INTERVAL = 60
M._usteer_filter_next = 0
M._usteer_filter_built = nil
function M._usteer_filter_resync()
	local u = M._usteer
	if not (u and u.reconcile_filter and u.filter_wanted) then return false end
	local now = M._time()
	if M._not_due(M._usteer_filter_next, now, M.USTEER_FILTER_INTERVAL) then return false end
	M._usteer_filter_next = now + M.USTEER_FILTER_INTERVAL
	local names = {}
	if u.filter_wanted() then
		names = M._l2guard_live_ifnames()
		if #names == 0 then return false end
	end
	local key = table.concat(names, " ")
	if key == M._usteer_filter_built then return false end
	u.reconcile_filter(names)
	M._usteer_filter_built = key
	return true
end

-- ─── The controller's scheduled neighbour scan ──────────────────────────────

-- Opt-in background neighbour scan (conf.lua neighbour_scan_interval, in
-- seconds; 0/nil = off). scan_radio_table is read from the kernel's cached
-- BSS list, and cfg80211 drops a cached BSS about 30 s after it was last
-- seen -- and the controller drops anything with age >= 30 on top. Nothing
-- else in openUF ever scans (the spectrum-scan cmd is never issued by
-- 10.4.57), so after the boot-time ACS sweep the Environment view drains to
-- empty, and any parent-AP list built from neighbours would have nothing to
-- work from. A scan takes the radio off-channel for a moment, which clients
-- see as a brief stall -- the reason this is off by default. Returns true
-- when a scan was issued.
--
-- Where `syswrapper.sh 11k-scan` -- the controller's nightly cron job, see
-- sysconf.lua -- leaves its dated request. Consumed and removed by the next
-- heartbeat; ignored when older than SCAN_REQUEST_MAX_AGE, so a request a
-- stopped daemon never saw does not fire at the next boot in the middle of
-- hostapd's ACS sweep.
M.SCAN_REQUEST_FILE    = "/tmp/openuf-scan-request"
M.SCAN_REQUEST_MAX_AGE = 600
-- The request holds one epoch per line, each a time a scan falls due: two of
-- them, randomised inside this window by syswrapper.sh 11k-scan, as UniFi
-- firmware spreads the job (elevenk_sched 3600 2, firmware-confirmed for
-- 4.0.15: every AP's crond fires at 04:00 sharp, and without the spread all
-- APs go off-channel together and find each other off-channel too).
M.SCAN_REQUEST_WINDOW  = 3600

-- One blocking off-channel sweep on an AP netdev: `iw dev <if> scan
-- ap-force`. A plain `scan` does sweep on a beaconing AP with the drivers
-- seen so far: AP2 (mt7986/mt76, OpenWrt 25.12) answered one with 26
-- scan_table rows on 2026-09-15, and upstream compared plain and `ap-force`
-- channel by channel on ath9k/ath10k and mt76 (2026-09-25) and found them
-- identical. `ap-force` (NL80211_SCAN_FLAG_AP) is kept as a free guard for
-- a driver/kernel that does refuse. What matters more is the exit status:
-- _popen drops stderr, so a refused scan used to be indistinguishable from
-- a successful one, and the 11k-scan count was of commands sent, not of
-- sweeps that ran. The scan output itself is discarded (callers read the
-- kernel's caches: `scan dump`, `survey dump`). Returns true when the sweep
-- ran; logs and returns false when iw refused.
-- The RF views' channel tables (airview bundle, 10.6.106) offer 20/40 MHz
-- on 2.4 GHz and 20/40/80/160 on 5 GHz, and a row is read only under the
-- tab whose width it names -- so one sweep is reported at every width.
local SPECTRUM_WIDTHS = {ng = {20, 40}, na = {20, 40, 80, 160}}

-- The controller's band index in a quick-scan ("scan-band") and the band
-- word in a scan_band, as the band openUF's radios report (ucihelper's
-- band_for_device: a 6 GHz radio reports "na" too). nil for anything else.
function M._scan_band_name(v)
	if v == 0 or v == "0" or v == "ng" then return "ng" end
	if v == 1 or v == "1" or v == "na" then return "na" end
	if v == 2 or v == "2" or v == "6e" then return "na" end
	return nil
end

-- Centre of the <width> MHz block a 20 MHz channel belongs to. 5 GHz blocks
-- are aligned from channel 36 (5180) and again from 149 (5745), which is
-- why 149-177 at 160 MHz centres on 5815 and not on an extension of the
-- lower run; 2.4 GHz pairs channels 1-7 upward and the rest downward.
function M._block_center(freq, width)
	if width <= 20 then return freq end
	if freq < 3000 then
		return (freq <= 2442) and (freq + 10) or (freq - 10)
	end
	local base = (freq >= 5745) and 5745 or 5180
	local idx = math.floor((freq - base) / width)
	return base + idx * width + (width - 20) / 2
end

-- Survey counters -> spectrum_table rows: one per 20 MHz channel per width
-- its band offers. The view averages the rows of one width whose channel
-- lies inside a block, so each row carries its own channel's figures.
-- utilization is busy airtime in %, interference the busy time that was
-- neither this radio's rx nor its tx (other energy on the channel) in %;
-- both 0..100, which is what the bars and Radio AI's reader expect -- an
-- earlier version put the noise floor in dBm here, a negative "percent".
-- Channels the sweep never visited (no active time) are left out rather
-- than reported as 0 %: the view marks a missing block "not available",
-- a 0 would say "idle". Without rx/tx counters there is no interference
-- figure and the field is omitted (the reducer skips an absent one).
function M._spectrum_rows(stats)
	local rows = {}
	for _, s in ipairs(stats or {}) do
		local total = tonumber(s.channel_time) or 0
		local ch = s.freq and M._sysinfo.channel_from_freq(s.freq)
		if total > 0 and ch then
			local busy = tonumber(s.channel_time_busy) or 0
			local function pct(v)
				return math.max(0, math.min(100, math.floor(v * 100 / total + 0.5)))
			end
			local other = nil
			if s.channel_time_rx or s.channel_time_tx then
				other = pct(busy - (tonumber(s.channel_time_rx) or 0)
					- (tonumber(s.channel_time_tx) or 0))
			end
			for _, w in ipairs(SPECTRUM_WIDTHS[s.freq < 3000 and "ng" or "na"]) do
				rows[#rows + 1] = {
					channel      = ch,
					width        = w,
					center_freq  = M._block_center(s.freq, w),
					utilization  = pct(busy),
					interference = other,
				}
			end
		end
	end
	return rows
end

-- A device event (EVT_AP_*) is an inform of its own: the regular payload
-- plus `inform_as_notif`, `notif_reason` ("event") and a `notif_payload`
-- whose `event_string` names the handler. The controller's inform entry
-- (devmgr.l, 10.6.106) takes that branch before any statistics processing
-- -- the identity fields are read as usual, the tables are not -- and
-- answers a bare noop. Posted right after the heartbeat that carried the
-- sweep's table (_tick), from that heartbeat's own JSON so nothing is
-- rebuilt. Returns true when the controller took it.
function M._post_notif(st, cfg, json_str)
	local notif = M._pending_notif
	M._pending_notif = nil
	if type(notif) ~= "table" then return false end
	local ok, payload = pcall(cjson.decode, json_str)
	if not ok or type(payload) ~= "table" then return false end
	payload.inform_as_notif = true
	payload.notif_reason    = "event"
	payload.notif_payload   = notif
	local ok_p, pkt = pcall(M.build_packet, M._fix_empty_arrays(cjson.encode(payload)), st)
	if not ok_p then
		io.stderr:write("inform: event " .. tostring(notif.event_string)
			.. ": build_packet failed: " .. tostring(pkt) .. "\n")
		return false
	end
	local body, err = M.http_post(st.inform_url, pkt)
	if not body then
		io.stderr:write("inform: event " .. tostring(notif.event_string)
			.. " not delivered: " .. tostring(err) .. "\n")
		return false
	end
	if cfg and cfg.config and cfg.config.debug_dump_requests then
		M._debug_append(cfg, "TX", "notif " .. tostring(notif.event_string))
	end
	return true
end

-- The `scan` cmd's radio choice: a radio_name names that radio (nothing is
-- swept when no reported radio has the name), a frequency without one names
-- the band that can tune it (the controller's own band table: 6 GHz starts
-- at 5925), neither sweeps every radio. `type` (active/passive) is not
-- honoured: the sweep runs the way every other one does. Returns how many
-- radios were queued.
function M._handle_scan_cmd(resp, cfg)
	local band
	local rn = resp.radio_name
	if type(rn) == "string" and rn ~= "" then
		local ufuci = M._ucihelper
		local ok_r, radios = pcall(ufuci and ufuci.get_radio_table or function() end,
			cfg and cfg.uap and cfg.uap.hwassign)
		for _, r in ipairs(ok_r and type(radios) == "table" and radios or {}) do
			if r.name == rn then band = r.radio end
		end
		if not band then
			io.stderr:write("inform: scan: unknown radio " .. rn .. " -- nothing swept\n")
			return 0
		end
	else
		local mhz = tonumber(tostring(resp.freq or ""):match("%d+"))
		if mhz then band = mhz < 3000 and "ng" or "na" end
	end
	return M._spectrum_scan(cfg, band, "scan")
end

-- One forced sweep per radio -- every radio, or those on `band` -- and the
-- survey counters afterwards become that radio's spectrum_table (cached in
-- M._spectrum_cache, reported by every build_json until the next sweep).
-- Blocking, a few seconds per radio, which is the point: the inform that
-- follows the command carries the result. A refused sweep still leaves the
-- operating channel's survey, so the table is built either way (_force_scan
-- has logged the refusal). Returns how many radios were swept.
function M._spectrum_scan(cfg, band, who)
	local ufuci = M._ucihelper
	if not (ufuci and ufuci.get_radio_table and ufuci.get_ifname_for_radio) then return 0 end
	local ok_r, radios = pcall(ufuci.get_radio_table, cfg and cfg.uap and cfg.uap.hwassign)
	if not ok_r or type(radios) ~= "table" then return 0 end
	local queued = 0
	for _, radio in ipairs(radios) do
		if band == nil or radio.radio == band then
			local ok_if, ifname = pcall(ufuci.get_ifname_for_radio, radio.name)
			if ok_if and ifname then
				-- One job per radio. The same kind of sweep asked again while
				-- its job is still running is already being done: keep the job
				-- and its progress (a neighbour_scan_interval shorter than the
				-- sweep -- 90 s on AP2, 2026-10-03 -- otherwise restarted the
				-- 5 GHz sweep every time and it never got past its first
				-- chunk). A DIFFERENT kind replaces the job where it stands:
				-- a Quick Scan is not made to wait behind the nightly sweep.
				local slot = nil
				for i, job in ipairs(M._scan_jobs) do
					if job.radio.name == radio.name then slot = i; break end
				end
				if slot and M._scan_jobs[slot].who == who then
					queued = queued + 1
				else
					local freqs = nil
					if M._sysinfo and M._sysinfo.phy_frequencies then
						local ok_f, f = pcall(M._sysinfo.phy_frequencies, ifname)
						if ok_f and type(f) == "table" and #f > 0 then freqs = f end
					end
					local job = {radio = radio, ifname = ifname, who = who, freqs = freqs, next = 1}
					if slot then M._scan_jobs[slot] = job else M._scan_jobs[#M._scan_jobs + 1] = job end
					queued = queued + 1
				end
			end
		end
	end
	return queued
end

-- True while a sweep of that kind ("quick-scan", "spectrum-scan", ...) is
-- still queued or running.
function M._scan_job_active(who)
	for _, job in ipairs(M._scan_jobs) do
		if job.who == who then return true end
	end
	return false
end

-- One heartbeat's share of the oldest sweep: the next SCAN_CHUNK_CHANNELS
-- channels of its list (or the whole band when the list could not be read),
-- then the survey counters become the radio's spectrum_table so far, and --
-- for the two commands the controller dates by it -- an EVT_AP_QuickScanEvent
-- carrying one row of this chunk is queued (_post_notif). The controller's
-- handler upserts that row and stamps the record's spectrum_scan_timestamp,
-- which is the Quick Scan card's "last scan" and what Radio AI's prescan
-- watches as the rows come in; the table itself rides every inform. The job
-- is dropped after its last chunk. Returns true when a chunk ran.
function M._scan_job_tick()
	local job = M._scan_jobs[1]
	if not job then return false end
	local ufuci = M._ucihelper
	if not (ufuci and ufuci._popen) then
		table.remove(M._scan_jobs, 1)
		return false
	end
	local chunk = nil
	if job.freqs then
		chunk = {}
		local last = math.min(job.next + M.SCAN_CHUNK_CHANNELS - 1, #job.freqs)
		for i = job.next, last do chunk[#chunk + 1] = job.freqs[i].freq end
		job.next = last + 1
	end
	M._force_scan(ufuci, job.ifname, job.who, chunk)
	io.stderr:write(string.format("inform: %s: swept %s on %s (%d channel(s) left)\n", tostring(job.who),
		chunk and (#chunk .. " channel(s)") or "the whole band", tostring(job.ifname),
		job.freqs and math.max(0, #job.freqs - job.next + 1) or 0))
	local ok_rs, stats = pcall(M._sysinfo.radio_stats, job.ifname)
	if ok_rs then
		local rows = M._spectrum_rows(stats)
		M._spectrum_cache[job.radio.name] = {table = rows, scanned_at = M._time()}
		if job.who == "quick-scan" or job.who == "spectrum-scan" then
			local pick = nil
			if chunk and M._sysinfo.channel_from_freq then
				local want = {}
				for _, f in ipairs(chunk) do
					local ch = M._sysinfo.channel_from_freq(f)
					if ch then want[ch] = true end
				end
				for _, r in ipairs(rows) do
					if want[r.channel] and r.width == 20 then pick = r; break end
				end
			end
			pick = pick or rows[1]
			if pick then
				M._pending_notif = {
					event_string = "EVT_AP_QuickScanEvent",
					radio        = job.radio.radio,
					radio_name   = job.radio.name,
					channel      = pick.channel,
					width        = pick.width,
					center_freq  = pick.center_freq,
					utilization  = pick.utilization,
					interference = pick.interference or 0,
				}
			end
		end
	end
	if not job.freqs or job.next > #job.freqs then
		table.remove(M._scan_jobs, 1)
	end
	return true
end

function M._force_scan(ufuci, ifname, who, freqs)
	-- `freq ...` limits the sweep to those channels (one chunk of a job);
	-- without it the whole band, as the 11k path always did.
	local extra = ""
	if type(freqs) == "table" and #freqs > 0 then
		local list = {}
		for _, f in ipairs(freqs) do
			local n = tonumber(f)
			if n then list[#list + 1] = tostring(math.floor(n)) end
		end
		if #list > 0 then extra = " freq " .. table.concat(list, " ") end
	end
	local out = ufuci._popen("iw dev " .. ifname
		.. " scan ap-force" .. extra .. " >/dev/null 2>&1 && echo scan-ok") or ""
	if out:find("scan-ok", 1, true) then return true end
	io.stderr:write("inform: " .. who .. ": iw refused to scan " .. ifname .. "\n")
	return false
end

-- A sweep of every reported radio (the modelmap's hwassign, as build_json
-- uses), queued in chunks like every other sweep (M._scan_jobs): the
-- `scan dump` fills in over the following heartbeats instead of all at once
-- after three seconds of radio silence. Returns how many radios were queued.
function M._scan_all_radios(cfg)
	return M._spectrum_scan(cfg, nil, "11k-scan")
end

-- True when one of the pending 11k-scan due times has come. The times that
-- fired or went stale are taken out of the file, so each is served at most
-- once; the file is removed when nothing is left in it. A due time more than
-- SCAN_REQUEST_MAX_AGE in the past is dropped unscanned, so a request a
-- stopped daemon never saw does not fire at the next boot in the middle of
-- hostapd's ACS sweep; one further ahead than the window (the clock stepped
-- back) is dropped too.
function M._scan_requested()
	local raw = M._read_file(M.SCAN_REQUEST_FILE)
	if not raw then return false end
	local now = M._time()
	local due, stale, keep = false, false, {}
	for s in raw:gmatch("%d+") do
		local late = now - tonumber(s)
		if late > M.SCAN_REQUEST_MAX_AGE or late < -(M.SCAN_REQUEST_WINDOW + 60) then
			stale = true
		elseif late >= 0 then
			due = true
		else
			keep[#keep + 1] = s
		end
	end
	if stale or not (due or #keep > 0) then
		io.stderr:write("inform: ignoring a stale 11k-scan request\n")
	end
	if #keep == 0 then
		os.remove(M.SCAN_REQUEST_FILE)
	elseif due or stale then
		local f = io.open(M.SCAN_REQUEST_FILE, "w")
		if f then f:write(table.concat(keep, "\n"), "\n"); f:close() end
	end
	return due
end

function M._maybe_scan_neighbours(cfg, ctx)
	-- A sweep still in its chunks is never started over, and a due time is
	-- left in the file until it can run: the second of the hour's two scans
	-- lands while the first is still sweeping on a two-radio board.
	if M._scan_job_active("11k-scan") then return false end
	-- The controller's scheduled scan first: it asked, so it runs now,
	-- whatever the interval option says and even on the first pass.
	if M._scan_requested() then
		io.stderr:write("inform: 11k-scan requested -- scanning every radio\n")
		ctx.last_scan = M._time()
		return M._scan_all_radios(cfg) > 0
	end
	local every = tonumber(cfg and cfg.config and cfg.config.neighbour_scan_interval)
	if not every or every <= 0 then return false end
	local now = M._time()
	-- Never on the first pass: hostapd's own ACS scan is still running at
	-- boot, and a restart must not cost every client a stall.
	if not ctx.last_scan then ctx.last_scan = now; return false end
	if now - ctx.last_scan < every then return false end
	-- (A sweep still in its chunks returned above: the interval counts from
	-- the start of one sweep to the start of the next, and a sweep takes
	-- ~11 heartbeats across two radios.)
	ctx.last_scan = now
	return M._scan_all_radios(cfg) > 0
end

-- ─── 802.11r key-exchange socket (rrbguard.lua) ─────────────────────────────

-- Once a minute: is hostapd's 802.11r key-exchange socket still bound? See
-- rrbguard.lua. The night repair window needs a trusted clock; without one
-- only the no-clients path can repair.
function M._rrbguard_tick()
	local g = M._rrbguard
	if not (g and g.tick) then return nil end
	local now = M._time()
	local hour = M._clock_trusted() and os.date("*t", now).hour or nil
	return g.tick(now, hour)
end

-- Until 2026-11-02 openUF pointed hostapd at the veth of its own vendored
-- 802.11r translator. A device upgraded from such a build still has those
-- WLAN options and the veth sections; the sections may only go once the
-- WLANs no longer name the veth (ucihelper.remove_legacy_ft_veth, after the
-- reload of a push), so the controller is asked to push again, once.
function M._migrate_legacy_rrb(st, cfg)
	local ok, present = pcall(M._ucihelper.legacy_ft_veth_present)
	if not (ok and present) then return false end
	if st.adopted and st.cfgversion ~= "" then
		st.cfgversion = ""
		M._state.save(st)
		io.stderr:write("openuf: this device still carries the veth of openUF's former built-in "
			.. "802.11r translator; the controller is asked to push the WLANs again, after which "
			.. "the veth is removed (the translator is a separate install now, see USAGE.md)\n")
	end
	return true
end

-- ─── WiFi Blackout Schedule ─────────────────────────────────────────────────

-- WiFi Blackout Schedule (wlansched.lua): each heartbeat, every scheduled
-- WLAN outside its schedule's on-times is taken down, as the firmware's
-- configure_vap does with ifconfig, and brought back up when they start
-- again. hostapd stops and restarts that BSS alone when its netdev goes
-- down and up. The ifnames taken down are kept in st.sched_vaps_down, so
-- a restart in between still brings them up. Nothing is done before the
-- clock is known to be right (_clock_trusted): the firmware keeps every
-- VAP up until NTP has set the time, and after a boot every VAP starts up.
function M._sched_resync(st)
	local ufuci = M._ucihelper
	if not (ufuci and ufuci.schedule_vaps) then return false end
	if not M._clock_trusted() then return false end
	local ok, vaps = pcall(ufuci.schedule_vaps)
	if not ok or type(vaps) ~= "table" then return false end
	if #vaps == 0 and not st.sched_vaps_down then return false end
	local t = os.date("*t", M._time())
	local down = M._wlansched.down_set(vaps, t.wday - 1, t.hour * 60 + t.min)
	-- keep: VAPs something else holds down (the Uplink Connectivity
	-- Monitor, guest selfrun), which the schedule must not bring back up.
	local keep = {}
	for _, n in ipairs(st.uplinkmon_down or {}) do keep[n] = true end
	for _, n in ipairs(st.guest_vaps_down or {}) do keep[n] = true end
	local held, changed = M._wlansched.reconcile(down, st.sched_vaps_down, keep)
	if #changed.down > 0 then
		io.stderr:write("wlansched: outside the WLAN schedule -- down: "
			.. table.concat(changed.down, " ") .. "\n")
	end
	if #changed.up > 0 then
		io.stderr:write("wlansched: inside the WLAN schedule again -- up: "
			.. table.concat(changed.up, " ") .. "\n")
	end
	if #held == 0 then held = nil end
	local before = table.concat(st.sched_vaps_down or {}, " ")
	if before ~= table.concat(held or {}, " ") then
		st.sched_vaps_down = held
		M._state.save(st)
	end
	return #changed.down > 0 or #changed.up > 0
end

-- ─── Uplink Connectivity Monitor ────────────────────────────────────────────

-- Each heartbeat (uplinkmon.lua): ping the monitor target; after FAIL_TICKS
-- failed verdicts take the user and guest SSIDs' BSS netdevs down, and bring
-- them back on the first answer, as the firmware's uplink-monitor does. Shares the schedule's mechanism (wlansched.reconcile), each
-- keeping the other's netdevs down, so a WLAN schedule opening never puts an
-- SSID back on the air while the uplink is dead, nor the uplink returning
-- one the schedule has off. conf.lua's uplink_monitor (true/false) overrides
-- the controller's switch; uplink_monitor_host names the host to ping.
function M._uplinkmon_resync(st, cfg)
	local um, ufuci = M._uplinkmon, M._ucihelper
	if not (um and ufuci and ufuci.ap_ifnames and M._wlansched) then return false end
	local c = cfg and cfg.config or {}
	local enabled = st.uplinkmon_enabled == true
	if type(c.uplink_monitor) == "boolean" then enabled = c.uplink_monitor end
	if not enabled and not st.uplinkmon_down then
		um.decide(false)
		return false
	end
	local host = c.uplink_monitor_host
	if host == "" then host = nil end
	host = host or st.uplinkmon_host
	-- Not `enabled and um.reachable(host) or nil`: a failed ping (false)
	-- would read as unknown and the monitor would never act.
	local reachable = nil
	if enabled then reachable = um.reachable(host) end
	local isolated = um.decide(enabled, reachable, st.uplinkmon_down ~= nil)
	local down = {}
	if isolated then
		local ok, names = pcall(ufuci.ap_ifnames)
		names = (ok and type(names) == "table") and names or {}
		-- Wireless not answering: leave things as they are rather than read
		-- an empty list as "bring everything back".
		if #names == 0 then return false end
		for _, n in ipairs(names) do
			-- BSS netdevs only: a private key's VLAN netdev has no hostapd
			-- of its own to restart a beacon on, and goes with its BSS.
			if not ufuci.bss_ifname or ufuci.bss_ifname(n) == n then down[n] = true end
		end
	end
	local keep = {}
	for _, n in ipairs(st.sched_vaps_down or {}) do keep[n] = true end
	for _, n in ipairs(st.guest_vaps_down or {}) do keep[n] = true end
	local held, changed = M._wlansched.reconcile(down, st.uplinkmon_down, keep)
	if #changed.down > 0 then
		io.stderr:write("uplinkmon: uplink unreachable -- SSIDs off the air: "
			.. table.concat(changed.down, " ") .. "\n")
	end
	if #changed.up > 0 then
		io.stderr:write("uplinkmon: uplink reachable again -- SSIDs back: "
			.. table.concat(changed.up, " ") .. "\n")
	end
	if #held == 0 then held = nil end
	if table.concat(st.uplinkmon_down or {}, " ") ~= table.concat(held or {}, " ") then
		st.uplinkmon_down = held
		M._state.save(st)
	end
	return #changed.down > 0 or #changed.up > 0
end

-- The firmware's /var/run/ntp.ready, which its ntpclient writes once it has
-- set the clock. OpenWrt's ntpd leaves no such mark, so openUF writes its
-- own once a controller answer's server_time_in_utc agrees with the local
-- clock. Under /var/run like the firmware's: it outlives a restart of
-- openUF, not a reboot.
M.CLOCK_OK_FILE = "/var/run/openuf.clock-ok"
M.CLOCK_MAX_SKEW = 60
M._clock_ok = false
function M._clock_trusted()
	if M._clock_ok then return true end
	M._clock_ok = M._read_file(M.CLOCK_OK_FILE) ~= nil
	return M._clock_ok
end
-- A clock the controller says is off means ntpd is not doing its job, and
-- openUF restarts it (sysntpd) rather than set the clock itself. BusyBox ntpd
-- started at boot before its servers could be resolved never syncs: on two
-- JIDU6401s after a power cut both clocks stayed 10 and 28 minutes off for
-- hours (2026-10-28), and a mesh child that boots without its cable does it
-- every time (2026-10-29). fast-roaming's rrb-unifi then drops every roam
-- message between the APs ("clock differs by N s"). At most once per
-- NTP_KICK_INTERVAL, doubling while restarts do not help (a controller whose
-- own clock is wrong), up to NTP_KICK_MAX; an answer that agrees starts over.
-- The interval is timed on /proc/uptime, which a clock step does not move.
M.NTP_KICK_INTERVAL = 300
M.NTP_KICK_MAX = 3600
M._ntp_kick_at = nil
M._ntp_kicks = 0
function M._uptime()
	return tonumber(((M._read_file("/proc/uptime") or ""):match("^(%d+)")))
end
function M._note_server_time(resp)
	if type(resp) ~= "table" then return end
	local ms = tonumber(resp.server_time_in_utc)
	if not ms then return end
	local skew = M._time() - ms / 1000
	if math.abs(skew) <= M.CLOCK_MAX_SKEW then
		M._ntp_kicks = 0
		if not M._clock_ok then
			M._clock_ok = true
			M._touch(M.CLOCK_OK_FILE)
		end
		return
	end
	local up = M._uptime() or 0
	local wait = math.min(M.NTP_KICK_INTERVAL * 2 ^ math.max(M._ntp_kicks - 1, 0), M.NTP_KICK_MAX)
	if M._ntp_kick_at and up - M._ntp_kick_at < wait then return end
	M._ntp_kick_at = up
	M._ntp_kicks = M._ntp_kicks + 1
	io.stderr:write(("openuf: the clock is %d s %s the controller's -- restarting ntpd (try %d)\n"):format(
		math.floor(math.abs(skew) + 0.5), skew < 0 and "behind" or "ahead of", M._ntp_kicks))
	M._run_cmd("/etc/init.d/sysntpd restart >/dev/null 2>&1")
end
M._touch = function(path)
	local f = io.open(path, "w")
	if f then f:close() end
end

-- ─── STUN wake-up ────────────────────────────────────────────────────────────

-- Injectable: LuaSocket, for the STUN client's UDP socket.
M._socket = function() return require("socket") end

-- The STUN client (stun.lua): opened while the AP is adopted and the
-- controller named a STUN server, closed otherwise. Once per tick, before
-- the inform, so a Binding Request goes out every stun.INTERVAL seconds and
-- the mapped address it learns rides out as connect_request_ip/port.
M._stun_c = nil
function M._stun_tick(st)
	local c = M._stun_c
	if not c then
		c = M._stun.new(M._socket())
		M._stun_c = c
	end
	-- The firmware runs STUN only while managed.
	local active = st.adopted == true
	local ok, err = M._stun.sync(c, st.stun_url, active)
	if ok then
		local _, err2 = M._stun.send_due(c, M._time())
		err = err2
	end
	-- Said once per distinct failure, not every retry.
	if err and err ~= c.last_err then
		io.stderr:write("inform: stun: " .. tostring(err) .. "\n")
	end
	c.last_err = err
end

-- Read the STUN socket. True when the controller asked for an inform, or
-- the mapped address it should send that request to changed.
function M._stun_wake()
	local c = M._stun_c
	if not c then return false end
	local ok, wake = pcall(M._stun.receive, c)
	return ok and wake == true
end

-- The RADIUS DAS dispatcher (das.lua): a UDP socket on st.das.port while
-- the last push left WLANs to relay for, served from M._idle. Rebound when
-- the port changes, closed when the plan goes. A port it cannot bind is
-- tried again every tick and said once.
M._das_sock, M._das_port, M._das_wlans, M._das_failed = nil, nil, nil, nil
function M._das_sync(st)
	local plan = type(st) == "table" and st.das
	local port = type(plan) == "table" and type(plan.wlans) == "table"
		and #plan.wlans > 0 and tonumber(plan.port) or nil
	M._das_wlans = port and plan.wlans or nil
	if M._das_sock and M._das_port ~= port then
		M._das_sock:close()
		M._das_sock, M._das_port = nil, nil
	end
	if not port then M._das_failed = nil end
	if not port or M._das_sock then return end
	local socket = M._socket()
	local u = (socket.udp4 or socket.udp)()
	local ok, err = u:setsockname("*", port)
	if not ok then
		u:close()
		if M._das_failed ~= port then
			io.stderr:write(("inform: RADIUS DAS: cannot listen on udp/%d (%s) -- CoA/Disconnect for %d WLAN(s) is off until it can\n")
				:format(port, tostring(err), #plan.wlans))
		end
		M._das_failed = port
		return
	end
	u:settimeout(0)
	M._das_sock, M._das_port, M._das_failed = u, port, nil
end

-- Answer one datagram on the DAS socket. False when nothing was there.
function M._das_serve(sock)
	local data, ip, port = sock:receivefrom()
	if not data then return false end
	local ok, answer = pcall(M._das.handle, M._das_wlans, data, ip,
		M._das.udp_relay(M._socket()))
	if ok and answer then sock:sendto(answer, ip, port) end
	return true
end

-- Sleep for wait seconds, ending early when the STUN socket says to inform
-- now: the controller's 0x8888 connection request, sent the moment it queues
-- a command or a config change, so Locate, Reconnect and a WLAN edit land
-- within a second instead of at the next heartbeat.
-- While roam reports are on (M._roam_fast), it also wakes every ROAM_POLL_S
-- to look at the collector's file (_roam_poll): the controller pairs a
-- departure with an arrival only within 10 s, and calls the roam failed
-- when the departure arrived more than a second ahead.
-- While the guest portal listens (M._guest_server), its socket is waited on
-- too and each guest is answered as it arrives; a readable socket with
-- nothing to accept is left alone for the rest of this wait, so it cannot
-- spin.
-- While the DAS relay listens (M._das_sock), each request is relayed and
-- answered as it arrives, within the RADIUS server's retry timeout.
-- While a mesh child's wired socket is watched (backhaul.watching), it wakes
-- every CARRIER_POLL_S and ends the wait when that link has changed.
function M._idle(socket, wait, state_changed)
	local deadline = socket.gettime() + wait
	local fast = M._roam_fast
	local bh = M._backhaul
	local watch = bh and bh.watching and bh.watching() or false
	local guests, das_on = true, true
	while true do
		local left = deadline - socket.gettime()
		-- A backward clock step (NTP) makes `left` exceed the whole wait and
		-- the daemon stops informing for the step's length: restart the wait.
		if left > wait then
			deadline = socket.gettime() + wait
			left = wait
		end
		if left <= 0 then return end
		local step = fast and math.min(left, M.ROAM_POLL_S) or left
		if watch then step = math.min(step, M.CARRIER_POLL_S) end
		if state_changed then step = math.min(step, M.STATE_POLL_S) end
		local stun_sock = M._stun_c and M._stun_c.sock
		local server = guests and M._guest_server or nil
		local das_sock = das_on and M._das_sock or nil
		if not stun_sock and not server and not das_sock then
			socket.select(nil, nil, step)
			if not fast and not watch and not state_changed then return end
		else
			local want = {}
			if stun_sock then want[#want + 1] = stun_sock end
			if server then want[#want + 1] = server end
			if das_sock then want[#want + 1] = das_sock end
			local r = socket.select(want, nil, step)
			local stun_ready, guest_ready, das_ready = false, false, false
			for _, ready in ipairs(r or {}) do
				if ready == stun_sock then stun_ready = true end
				if ready == server then guest_ready = true end
				if ready == das_sock then das_ready = true end
			end
			if stun_ready and M._stun_wake() then return end
			if guest_ready and not M._guest_serve(server) then guests = false end
			-- Readable with nothing to read: leave it for the rest of this wait.
			if das_ready then
				local ok, served = pcall(M._das_serve, das_sock)
				if not (ok and served) then das_on = false end
			end
		end
		if fast then pcall(M._roam_poll) end
		if watch then
			local ok, changed = pcall(bh.carrier_changed)
			if ok and changed then return end
		end
		if state_changed then
			local ok, changed = pcall(state_changed)
			if ok and changed then return true end
		end
	end
end

-- Connection tracking runs only when the controller asked for it (mgmt_cfg
-- capability notif-assoc-stat) and conf.lua has not switched it off.
function M._assoc_enabled(st, cfg)
	if not M._assoctrack or type(st) ~= "table" or st.notif_assoc_stat ~= true then
		return false
	end
	return not (cfg and cfg.config and cfg.config.assoc_tracker == false)
end

-- Fold the drained collector lines into connection attempts and decide the
-- ones that are complete. The nft listing is skipped while nobody is
-- mid-connection, which is nearly every heartbeat.
function M._assoc_poll(blob)
	local at = M._assoctrack
	local evs = at.parse_events(blob)
	at.ingest(evs)
	at.roam_ingest(evs, M._vap_by_ifname)
	if next(at._stas) == nil then return evs end
	local up = tonumber(((M._read_file("/proc/uptime") or ""):match("^(%S+)")))
	if not up then return evs end
	at.poll({
		now = up, epoch = M._time(), sets = at.read_sets(up),
		vap_by_ifname = M._vap_by_ifname,
	})
	return evs
end

-- Kill a collector nobody wants any more, and stop asking once it is gone:
-- only collector_ensure starts one, and it clears the latch. A kill is not
-- latched, since collector_stop's success is never read back.
function M._reap_collector(rrm)
	if M._collector_reaped or not (rrm and rrm.collector_running) then return end
	local ok, running = pcall(rrm.collector_running)
	if not ok then return end
	if running then
		pcall(rrm.collector_stop)
		return
	end
	M._collector_reaped = true
end

-- Is there anything in the collector's event file? An open and a seek, against
-- drain()'s read of the whole file plus its truncating rewrite.
function M._events_pending(rrm)
	if not rrm.EVENT_FILE then return true end
	local f = io.open(rrm.EVENT_FILE, "r")
	if not f then return false end
	local size = f:seek("end")
	f:close()
	return (tonumber(size) or 0) > 0
end
end
