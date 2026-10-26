--[[
	ftinterop.lua -- 802.11r fast roaming between openUF and genuine UniFi APs.

	On by default for new installations (conf.lua / openuf.main
	`unifi_ft_interop`, the user's decision of 2026-10-25). Adopted from
	d-malinowski/openUF (branch pr/unifi-ft-interop, 2026-10-22); the hardware
	evidence is theirs: a BT Home Hub 5A on OpenWrt 25.12.6 roaming against a
	U7 Lite on UniFi 8.7.11, FT-PSK, both directions (PROTOCOL-VALIDATION.md,
	"802.11r with genuine UniFi APs"). Nothing here has run against a real UAP
	from this lab, which has none.

	Stock OpenWrt hostapd and UniFi's patched hostapd use the same FT key
	hierarchy and the same AES-SIV protected RRB payloads, but frame them
	differently: UniFi inserts the source and destination AP addresses (12
	bytes) after the RRB type, because it sends from the AP's Ethernet MAC and
	not the BSSID. The translator that converts between the two framings is
	part of openUF since 2026-10-25: rrb/rrb-unifi.uc (d-malinowski's
	rrb-unifi, vendored; rrb/README.md says what was changed and where fixes
	come from), run as the openuf-rrb service. hostapd's ft_iface is one end
	of a veth pair (vft0), the daemon holds the other end and the LAN bridge
	(ucihelper.ensure_ft_veth creates the pair). Nothing on the UniFi AP
	changes.

	Without the translator the switch changes only the mobility-domain
	formula (UniFi's, which every openUF AP still shares) and FT-PSK's key
	path (a pull over RRB instead of local derivation, the path FT-SAE takes
	anyway); nothing then points hostapd at a veth that does not exist. On a
	site with genuine UniFi APs but no translator, clients try a fast
	transition towards those APs and fall back to a full reconnect: the fix
	is the translator, or the switch off.

	With the framing handled by the daemon, what is left is config. This
	module supplies the four places where openUF's defaults differ from what
	a UniFi peer needs:

	  * mobility domain: UniFi firmware's own derivation, the first two
	    bytes of SHA1("salt" .. SSID zero-padded to 32 bytes). Their check:
	    the formula reproduces the mobility_domain in a live U7 Lite's own
	    hostapd config; SSID "corp" -> 5de5. openUF's default hash
	    (ucihelper.derive_mobility_domain) deliberately differs, so that
	    clients never try FT towards a UniFi AP without the translator.
	  * ft_psk_generate_local=0. OpenWrt defaults it to 1 for PSK and then
	    writes no key holders, so a UniFi AP pulling a PMK-R1 from this AP
	    gets no answer. This is the ONE place openUF sets the option (CLAUDE.md
	    says never to): with explicit key holders written alongside, FT-SAE
	    keeps the r0kh/r1kh relationship it needs.
	  * nas_identifier = this BSS's BSSID without colons, UniFi's R0KH-ID
	    convention: a UniFi AP derives the pull's destination address from the
	    R0KH-ID the client carries, so the two have to agree. OpenWrt's
	    hostapd.uc already defaults nas_identifier to exactly that (24.10 and
	    25.12: `bss.nasid ?? replace(bss.bssid, ":", "")`), so a first push
	    with no live netdev yet is still right; the explicit UCI option is
	    what `openuf rrb verify` reads, and what a reader sees.
	  * explicit key holders for every UniFi peer BSS of the WLAN, keyed with
	    the controller's iapp_key. The peers come from two places: the ones
	    the translator heard on the LAN (PEERS_FILE, with the mobility domain
	    of a verified roam announcement; inform.lua keeps them in state.json
	    and re-pushes when a new one appears), and any listed by hand as
	    openuf.rrb `list peer '<bssid>,<r0kh-id>'`. A UniFi AP's R0KH-ID is
	    its BSSID without colons (their firmware's `nas_identifier=$bssid`);
	    a hand entry can say otherwise. hostapd's pmk_r1_push skips wildcard
	    entries, so a peer only gets pushes when it is listed; an unlisted
	    one can still pull.

	And hostapd's ft_iface, as `hostapd_bss_options 'ft_iface=vft0'` and only
	when the translator is installed and enabled and its veth exists: an
	ft_iface that does not exist makes hostapd fail the BSS, and a veth
	nobody forwards would swallow every key exchange, openUF-to-openUF too.
	It is the raw option on purpose, not 25.12's first-class `ft_iface` UCI
	option: the generator then writes its own `ft_iface=<bridge>` line first
	and the override after it, and the translator reads that earlier line to
	learn which LAN interface the BSS is on. 24.10 has no ft_iface UCI option
	at all, so the raw form is also the one that works on both releases.

	reassociation_deadline is left at OpenWrt's default (openUF writes
	UniFi's 3000 TU otherwise), so an interop AP keeps the timing the
	translator was validated with.
]]

local M = {}
local util = package.loaded["openuf.util"]
	or assert(loadfile("util.lua") or loadfile("openuf/util.lua"))()

-- The translator's settings: the `rrb` section of /etc/config/openuf (the
-- init script documents every option). Its own section, like `web`: a `main`
-- section is what makes UCI replace conf.lua, and this must never create one.
M.RRB_CONFIG       = "openuf"
M.RRB_SECTION      = "rrb"
M.DEFAULT_FT_IFACE = "vft0"
-- What the daemon writes (RRB_PEERS_FILE in the init script).
M.PEERS_FILE       = "/var/run/openuf/rrb-peers.json"
-- The translator is installed when its service is, and its daemon sits next
-- to this module (cwd is the install directory when the daemons run; the
-- openuf/ form is for the test suite's cwd).
M.TRANSLATOR_FILES = {"/etc/init.d/openuf-rrb"}
M.DAEMON_FILES     = {"rrb/rrb-unifi.uc", "openuf/rrb/rrb-unifi.uc"}

-- Injectable seams.
M._read_file = util.read_file
M._exists = function(path)
	local f = io.open(path, "r")
	if f then f:close() return true end
	return false
end
M._log = function(msg) io.stderr:write("openuf: ftinterop: " .. msg .. "\n") end

-- ─── SHA1 (pure Lua, 32-bit words through util.bit) ──────────────────────────

local TWO32 = 4294967296

-- Lowercase hex SHA1 of msg. Every intermediate sum is reduced mod 2^32 by
-- hand, so the result does not depend on which bit library util.bit() found
-- (LuaBitOp returns signed words, bit32 unsigned ones, 5.3+ 64-bit integers).
function M.sha1(msg)
	local bit = util.bit()
	local band, bor, bxor = bit.band, bit.bor, bit.bxor
	local lshift, rshift = bit.lshift, bit.rshift
	local function u(x) return x % TWO32 end
	local function rol(x, n) return u(bor(lshift(x, n), rshift(u(x), 32 - n))) end
	local function bnot(x) return TWO32 - 1 - u(x) end

	local len = #msg
	msg = msg .. string.char(0x80)
	msg = msg .. string.rep(string.char(0), (56 - #msg % 64) % 64)
	local bits = len * 8
	local tail = {}
	for i = 8, 1, -1 do
		tail[i] = string.char(bits % 256)
		bits = math.floor(bits / 256)
	end
	msg = msg .. table.concat(tail)

	local h0, h1, h2, h3, h4 =
		0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0
	local w = {}
	for chunk = 1, #msg, 64 do
		for i = 0, 15 do
			local a, b, c, d = msg:byte(chunk + i * 4, chunk + i * 4 + 3)
			w[i] = ((a * 256 + b) * 256 + c) * 256 + d
		end
		for i = 16, 79 do
			w[i] = rol(bxor(bxor(w[i - 3], w[i - 8]), bxor(w[i - 14], w[i - 16])), 1)
		end
		local a, b, c, d, e = h0, h1, h2, h3, h4
		for i = 0, 79 do
			local f, k
			if i < 20 then
				f, k = bor(band(b, c), band(bnot(b), d)), 0x5A827999
			elseif i < 40 then
				f, k = bxor(bxor(b, c), d), 0x6ED9EBA1
			elseif i < 60 then
				f, k = bor(bor(band(b, c), band(b, d)), band(c, d)), 0x8F1BBCDC
			else
				f, k = bxor(bxor(b, c), d), 0xCA62C1D6
			end
			local t = u(rol(a, 5) + u(f) + e + k + w[i])
			e, d, c, b, a = d, c, rol(b, 30), a, t
		end
		h0, h1, h2 = u(h0 + a), u(h1 + b), u(h2 + c)
		h3, h4 = u(h3 + d), u(h4 + e)
	end
	-- %08x would raise for words >= 2^31 on OpenWrt's LNUM Lua (CLAUDE.md,
	-- "Lua"): format each word as two 16-bit halves instead.
	local out = {}
	for _, h in ipairs({h0, h1, h2, h3, h4}) do
		out[#out + 1] = string.format("%04x%04x", math.floor(h / 65536), h % 65536)
	end
	return table.concat(out)
end

-- UniFi firmware's mobility domain for an SSID (4 hex chars).
function M.mobility_domain(ssid)
	ssid = tostring(ssid or "")
	if #ssid < 32 then ssid = ssid .. string.rep(string.char(0), 32 - #ssid) end
	return M.sha1("salt" .. ssid):sub(1, 4)
end

-- A UniFi AP's R0KH-ID by its firmware's convention: the BSSID without colons.
function M.r0kh_id_of(bssid)
	return (bssid:lower():gsub(":", ""))
end

-- ─── the translator ──────────────────────────────────────────────────────────

-- Whether the translator service is installed here (it ships with openUF, so
-- this is only false on an install that predates it or lost the init script).
function M.translator_installed()
	for _, p in ipairs(M.TRANSLATOR_FILES) do
		if M._exists(p) then return true end
	end
	return false
end

-- Installed and not switched off (openuf.rrb.enabled '0'). Only then may
-- hostapd be pointed at the veth, and only then is the veth created.
function M.translator_active(cursor)
	if not M.translator_installed() then return false end
	local en = cursor and cursor:get(M.RRB_CONFIG, M.RRB_SECTION, "enabled")
	return en ~= "0"
end

-- The UniFi peer BSSes listed by hand (openuf.rrb `list peer`), as
-- {{bssid = "aa:bb:..", r0kh_id = "aabb.."}, ...}. Malformed entries are
-- dropped with a log line rather than written into hostapd's config: every
-- value here ends up as an r0kh/r1kh line hostapd parses, and the R0KH-ID
-- shape is hostapd's own ([\x21-\x7e]{1,48}, kept to the safe subset).
function M.peers(cursor)
	local raw = cursor and cursor:get(M.RRB_CONFIG, M.RRB_SECTION, "peer")
	if type(raw) == "string" then raw = {raw} end
	local out = {}
	for _, e in ipairs(type(raw) == "table" and raw or {}) do
		local bssid, r0 = tostring(e):match("^%s*([^,%s]+)%s*,%s*([^,%s]+)%s*$")
		bssid = bssid and bssid:lower()
		if util.is_mac(bssid) and r0 and r0:match("^[%w%-%._:]+$") and #r0 <= 48 then
			out[#out + 1] = {bssid = bssid, r0kh_id = r0}
		else
			M._log("ignoring malformed openuf.rrb peer entry " .. string.format("%q", tostring(e)))
		end
	end
	return out
end

-- What the daemon learned on the LAN (PEERS_FILE), as a list of
-- {bssid =, md = "5de5" | nil, seen =, via =}. Empty when the file is
-- missing, unreadable or not JSON; never raises (it runs every heartbeat).
function M.learned(read)
	read = read or M._read_file
	local raw = read(M.PEERS_FILE)
	if type(raw) ~= "string" or raw == "" then return {} end
	local ok, cjson = pcall(require, "cjson")
	if not ok then return {} end
	local ok2, tbl = pcall(cjson.decode, raw)
	if not ok2 or type(tbl) ~= "table" then return {} end
	local out = {}
	for key, p in pairs(tbl) do
		local bssid = type(key) == "string" and key:lower() or nil
		if util.is_mac(bssid) and type(p) == "table" then
			local md = type(p.md) == "string" and p.md:lower() or nil
			if md and not md:match("^%x%x%x%x$") then md = nil end
			out[#out + 1] = {bssid = bssid, md = md,
				seen = tonumber(p.seen), via = type(p.via) == "string" and p.via or nil}
		end
	end
	table.sort(out, function(a, b) return a.bssid < b.bssid end)
	return out
end

-- The key holders for one WLAN: every hand-listed peer, plus every learned
-- peer whose mobility domain is this WLAN's (`learned` is state.json's
-- {bssid = md} map; a peer with no domain yet is left out, since nothing
-- says which WLAN it serves). A hand entry wins over a learned one for the
-- R0KH-ID. Sorted, so the UCI lists are stable across pushes.
function M.peers_for(cursor, learned, md)
	local by = {}
	for bssid, pmd in pairs(learned or {}) do
		if type(pmd) == "string" and pmd:lower() == md and util.is_mac(bssid) then
			by[bssid:lower()] = M.r0kh_id_of(bssid)
		end
	end
	for _, p in ipairs(M.peers(cursor)) do by[p.bssid] = p.r0kh_id end
	local out = {}
	for bssid, r0 in pairs(by) do out[#out + 1] = {bssid = bssid, r0kh_id = r0} end
	table.sort(out, function(a, b) return a.bssid < b.bssid end)
	return out
end

-- The ft_iface hostapd should use, or nil: when the translator is not
-- active, or the veth does not exist (yet).
function M.ft_iface(cursor)
	if not M.translator_active(cursor) then return nil end
	local name = cursor and cursor:get(M.RRB_CONFIG, M.RRB_SECTION, "ft_iface")
	if type(name) ~= "string" or name == "" then name = M.DEFAULT_FT_IFACE end
	if not util.valid_ifname(name) then return nil end
	if not M._read_file("/sys/class/net/" .. name .. "/ifindex") then return nil end
	return name
end

-- ─── the UCI options ─────────────────────────────────────────────────────────

-- Rewrite one FT VAP's `extra` table (ucihelper.apply_config's option set)
-- for UniFi interop. `vap` is the parsed controller VAP, `bssid` this BSS's
-- address when known (nil: no nasid option is written; hostapd's own default
-- is the same value, and the next push fills the option in once the
-- interface is up). `cursor` reads openuf.rrb; `delete` is ucihelper.DELETE,
-- "this option must not be present"; `learned` is state.json's rrb_peers.
function M.apply(extra, vap, bssid, cursor, delete, learned)
	local installed = M.translator_installed()
	local md = M.mobility_domain(vap.ssid)
	extra.mobility_domain = md
	extra.ft_psk_generate_local = "0"
	extra.reassociation_deadline = delete
	if util.is_mac(bssid) then
		extra.nasid = M.r0kh_id_of(bssid)
	else
		M._log(string.format("%s on %s: BSSID not known yet, nasid left to hostapd's "
			.. "default (the BSSID) this push", tostring(vap.ssid), tostring(vap.radio)))
	end

	if vap.iapp_key then
		local key = vap.iapp_key
		local r0kh, r1kh = {}, {}
		for _, p in ipairs(M.peers_for(cursor, learned, md)) do
			r0kh[#r0kh + 1] = p.bssid .. "," .. p.r0kh_id .. "," .. key
			r1kh[#r1kh + 1] = p.bssid .. "," .. p.bssid .. "," .. key
		end
		r0kh[#r0kh + 1] = "ff:ff:ff:ff:ff:ff,*," .. key
		r1kh[#r1kh + 1] = "00:00:00:00:00:00,00:00:00:00:00:00," .. key
		extra.r0kh, extra.r1kh = r0kh, r1kh
		if #r0kh == 1 and installed then
			M._log(string.format("%s: no UniFi peer known for this WLAN yet (none heard on "
				.. "the LAN, none listed in openuf.rrb): UniFi peers can pull keys, but none "
				.. "get pushed", tostring(vap.ssid)))
		end
	else
		-- Without the controller's key OpenWrt derives one from the
		-- passphrase, which no UniFi AP shares.
		M._log(string.format("%s: the controller sent no iapp_key, "
			.. "fast roaming to UniFi APs will not work", tostring(vap.ssid)))
	end

	local ifn = M.ft_iface(cursor)
	if ifn then
		extra.hostapd_bss_options = {"ft_iface=" .. ifn}
	else
		extra.hostapd_bss_options = delete
		if installed and M.translator_active(cursor) then
			M._log("ft_iface not present, hostapd stays on the bridge: "
				.. "the translator's veth is not up (openuf rrb status)")
		end
	end
	if not installed then
		M._log(string.format("%s: the openuf-rrb translator service is not installed "
			.. "(reinstall openUF, or openuf deps --install); openUF APs still roam among "
			.. "themselves, fast roaming to genuine UniFi APs needs it", tostring(vap.ssid)))
	end
	return extra
end

return M
