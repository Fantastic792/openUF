-- Tests for openuf/meshvlan.lua: a tagged SSID's VLAN over the mesh hop on a
-- swconfig board. Nothing touches the host: sysfs, `ip` and `nft` are a fake
-- kernel that logs every operation in order, because the order -- guard before
-- port on the way in, port before guard on the way out -- is the safety
-- property.

local meshvlan = dofile("openuf/meshvlan.lua")

-- devs: netdevs present at the start ({name = {master=, up=}}).
-- opts.nft_fail(script) -> true makes nft reject that script (one transaction).
-- opts.ip_fail makes `ip link add` fail.
local function fake_kernel(devs, opts)
	opts = opts or {}
	local k = {devs = {}, log = {}}
	for name, d in pairs(devs or {}) do
		k.devs[name] = {master = d.master, up = d.up ~= false, learning = d.learning}
	end
	function k.read(path)
		local dev, rest = path:match("^/sys/class/net/([^/]+)/(.+)$")
		local d = dev and k.devs[dev]
		if not d then return nil end
		if rest == "ifindex" then return "7\n" end
		if rest == "master/uevent" then
			return d.master and ("MAJOR=0\nINTERFACE=" .. d.master .. "\nIFINDEX=9\n") or nil
		end
		if rest == "brport/learning" then
			if not d.master then return nil end
			return (d.learning == false) and "0\n" or "1\n"
		end
		if rest == "operstate" then return d.up and "up\n" or "down\n" end
		return nil
	end
	function k.write(path, v)
		local dev = path:match("^/sys/class/net/([^/]+)/brport/learning$")
		if dev and k.devs[dev] and k.devs[dev].master then
			k.devs[dev].learning = (v ~= "0")
			k.log[#k.log + 1] = "learning " .. dev .. " " .. v
			return true
		end
		k.log[#k.log + 1] = "write? " .. path
		return false
	end
	function k.exec(cmd)
		local path = cmd:match("^nft %-f (%S+)")
		if path then
			local lines = {}
			for line in io.lines(path) do lines[#lines + 1] = line end
			local script = table.concat(lines, "\n")
			if opts.nft_fail and opts.nft_fail(script) then
				k.log[#k.log + 1] = "nft refused"
				return 1
			end
			if script:find("add chain", 1, true) then
				k.guard = script
				k.log[#k.log + 1] = "nft guard"
			else
				k.guard = nil
				k.log[#k.log + 1] = "nft delete"
			end
			return 0
		end
		local link, name = cmd:match("^ip link add link (%S+) name (%S+) type vlan id %d+")
		if link then
			if opts.ip_fail then k.log[#k.log + 1] = "add refused"; return 1 end
			k.devs[name] = {up = false}
			k.log[#k.log + 1] = "add " .. name .. " on " .. link
			return 0
		end
		local dev, master = cmd:match("^ip link set dev (%S+) master (%S+)")
		if dev then
			k.devs[dev].master, k.devs[dev].learning = master, true
			k.log[#k.log + 1] = "master " .. dev .. " " .. master
			return 0
		end
		dev = cmd:match("^ip link set dev (%S+) up")
		if dev then
			k.devs[dev].up = true
			k.log[#k.log + 1] = "up " .. dev
			return 0
		end
		dev = cmd:match("^ip link del dev (%S+)")
		if dev then
			k.devs[dev] = nil
			k.log[#k.log + 1] = "del " .. dev
			return 0
		end
		k.log[#k.log + 1] = "other " .. cmd
		return 0
	end
	return k
end

local function with_kernel(k, fn)
	local o = {meshvlan._exec, meshvlan._read_file, meshvlan._write_file, meshvlan._log, meshvlan._time}
	local logs = {}
	meshvlan._exec, meshvlan._read_file, meshvlan._write_file = k.exec, k.read, k.write
	meshvlan._log = function(m) logs[#logs + 1] = m end
	local now = 1000
	meshvlan._time = function() return now end
	meshvlan._guard_ok, meshvlan._guard_next, meshvlan._warned = false, 0, {}
	local ok, err = pcall(fn, function(t) now = t end, logs)
	meshvlan._exec, meshvlan._read_file, meshvlan._write_file, meshvlan._log, meshvlan._time =
		o[1], o[2], o[3], o[4], o[5]
	if not ok then error(err, 0) end
end

local function joined(log) return table.concat(log, " | ") end

local function index_of(log, pattern)
	for i, l in ipairs(log) do if l:find(pattern) then return i end end
	return nil
end

local BASE = {["br-lan"] = {}, ["eth0.1"] = {master = "br-lan"}, ["br-openuf20"] = {}}

return {
	{
		name = "meshvlan: the guard lets a tagged frame through the LAN bridge's wireless ports only, both ways",
		fn = function()
			local stmts = meshvlan.guard_stmts("br-lan")
			local all = table.concat(stmts, "\n")
			assert_contains(all, "hook prerouting priority -300", "ingress before the bridge decides")
			assert_contains(all, "hook postrouting priority 0", "egress, forwarded and local alike")
			assert_contains(all, 'pre meta ibrname "br-lan" ether type vlan iifname != "phy*" '
				.. 'iifname != "wlan*" iifname != "ath*" drop', "in: only from a wireless port")
			assert_contains(all, 'post meta obrname "br-lan" ether type vlan oifname != "phy*" '
				.. 'oifname != "wlan*" oifname != "ath*" drop', "out: only to a wireless port")
			assert_eq(meshvlan.NFT_TABLE, "bridge openuf_meshvlan", "its own bridge table")
		end
	},
	{
		name = "meshvlan: reconcile() installs the guard before the port, and the port learns nothing",
		fn = function()
			local k = fake_kernel(BASE)
			with_kernel(k, function()
				local rec = meshvlan.record("br-lan", {20})
				assert_true(meshvlan.reconcile(rec, nil), "guard in")
				assert_eq(joined(k.log), "nft guard | add br-lan.20 on br-lan | master br-lan.20 br-openuf20"
					.. " | learning br-lan.20 0 | up br-lan.20", "guard, create, enslave, learning off, up -- in that order")
				assert_contains(k.guard, "add table bridge openuf_meshvlan\ndelete table bridge openuf_meshvlan\n"
					.. "add table bridge openuf_meshvlan\n", "one transaction that replaces any older copy")
			end)
		end
	},
	{
		name = "meshvlan: no guard, no port -- and a port that exists goes before the table does",
		fn = function()
			local refuse = function(script) return script:find("add chain", 1, true) ~= nil end
			local k = fake_kernel(BASE, {nft_fail = refuse})
			with_kernel(k, function(_, logs)
				local rec = meshvlan.record("br-lan", {20})
				assert_false(meshvlan.reconcile(rec, nil), "reported")
				assert_nil(index_of(k.log, "^add "), "no port without the guard")
				assert_contains(table.concat(logs, "\n"), "kmod-nft-bridge", "and said why")
			end)
			-- A guard that stops going in (resync) with a port already up.
			local devs = {["br-lan"] = {}, ["eth0.1"] = {master = "br-lan"}, ["br-openuf20"] = {},
				["br-lan.20"] = {master = "br-openuf20", learning = false}}
			k = fake_kernel(devs, {nft_fail = refuse})
			with_kernel(k, function()
				local rec = meshvlan.record("br-lan", {20})
				assert_false(meshvlan.resync(rec, 1000), "reported")
				local refused, del, delete = index_of(k.log, "^nft refused"), index_of(k.log, "^del br%-lan%.20"),
					index_of(k.log, "^nft delete")
				assert_true(refused and del and delete, "refused, port deleted, table deleted: " .. joined(k.log))
				assert_true(refused < del and del < delete, "in that order: " .. joined(k.log))
				assert_nil(k.devs["br-lan.20"], "the port is gone")
			end)
		end
	},
	{
		name = "meshvlan: reconcile(nil, prev) deletes the ports first, then the guard",
		fn = function()
			local k = fake_kernel(BASE)
			with_kernel(k, function()
				local rec = meshvlan.record("br-lan", {20})
				meshvlan.reconcile(rec, nil)
				k.log = {}
				assert_true(meshvlan.reconcile(nil, rec), "done")
				assert_eq(joined(k.log), "del br-lan.20 | nft delete", "port, then table")
			end)
		end
	},
	{
		name = "meshvlan: reconcile() drops the ports a new record no longer has, and keeps the rest",
		fn = function()
			local devs = {["br-lan"] = {}, ["eth0.1"] = {master = "br-lan"}, ["br-openuf20"] = {}, ["br-openuf30"] = {}}
			local k = fake_kernel(devs)
			with_kernel(k, function()
				local both = meshvlan.record("br-lan", {20, 30})
				meshvlan.reconcile(both, nil)
				assert_not_nil(k.devs["br-lan.30"], "30 carried")
				k.log = {}
				meshvlan.reconcile(meshvlan.record("br-lan", {20}), both)
				assert_eq(k.log[1], "del br-lan.30", "30 goes first")
				assert_nil(index_of(k.log, "del br%-lan%.20"), "20 stays")
				assert_not_nil(k.devs["br-lan.20"], "still there")
			end)
		end
	},
	{
		name = "meshvlan: resync() forks nothing when all is well, re-attaches what netifd took, puts the guard back each minute",
		fn = function()
			local k = fake_kernel(BASE)
			with_kernel(k, function(set_time)
				local rec = meshvlan.record("br-lan", {20})
				meshvlan.reconcile(rec, nil)
				k.log = {}
				set_time(1010)
				assert_true(meshvlan.resync(rec), "fine")
				assert_eq(#k.log, 0, "nothing to do, nothing done: " .. joined(k.log))
				-- netifd recreated br-openuf20: the port is out of it.
				k.devs["br-lan.20"].master = nil
				meshvlan.resync(rec)
				assert_eq(joined(k.log), "master br-lan.20 br-openuf20 | learning br-lan.20 0", "back in, learning off")
				-- netifd recreated br-lan: the VLAN device went with it.
				k.log = {}
				k.devs["br-lan.20"] = nil
				meshvlan.resync(rec)
				assert_eq(k.log[1], "add br-lan.20 on br-lan", "recreated")
				assert_not_nil(k.devs["br-lan.20"].master, "and enslaved")
				-- A minute on: the guard goes back in first.
				k.log = {}
				set_time(1000 + meshvlan.GUARD_INTERVAL)
				meshvlan.resync(rec)
				assert_eq(joined(k.log), "nft guard", "only the guard, the port is fine")
			end)
		end
	},
	{
		name = "meshvlan: a VLAN bridge netifd has not built yet is waited for, never created",
		fn = function()
			local k = fake_kernel({["br-lan"] = {}, ["eth0.1"] = {master = "br-lan"}})
			with_kernel(k, function()
				assert_eq(meshvlan.ensure_port("br-lan", 20), "waiting", "no br-openuf20 yet")
				assert_eq(#k.log, 0, "nothing created: " .. joined(k.log))
			end)
		end
	},
	{
		name = "meshvlan: a failed `ip link add` is said once and leaves nothing half-built",
		fn = function()
			local k = fake_kernel(BASE, {ip_fail = true})
			with_kernel(k, function(_, logs)
				assert_eq(meshvlan.ensure_port("br-lan", 20), "failed", "failed")
				assert_eq(meshvlan.ensure_port("br-lan", 20), "failed", "still")
				assert_nil(index_of(k.log, "^master"), "nothing enslaved")
				local n = 0
				for _, l in ipairs(logs) do if l:find("could not create br%-lan%.20") then n = n + 1 end end
				assert_eq(n, 1, "one log line, not one per heartbeat")
			end)
		end
	},
	{
		name = "meshvlan: record() keeps each valid VLAN id once, sorted, and refuses one whose port name cannot exist",
		fn = function()
			local k = fake_kernel({})
			with_kernel(k, function()
				local rec = meshvlan.record("br-lan", {30, "20", 20, 0, 5000, "x"})
				assert_eq(table.concat(rec.vids, ","), "20,30", "1..4094, once, sorted")
				assert_eq(rec.bridge, "br-lan", "bridge kept")
				assert_nil(meshvlan.record("br-lan", {}), "no VLAN: no record")
				assert_nil(meshvlan.record("br-lan with space", {20}), "an odd bridge name: no record")
				assert_nil(meshvlan.record("br-verylongname", {4094}), "br-verylongname.4094 exceeds IFNAMSIZ")
				-- What a JSON round trip can hand back.
				assert_eq(table.concat(meshvlan.vids_of({vids = {["1"] = 20, ["2"] = "30"}}), ","), "20,30",
					"string keys and string values")
				assert_eq(#meshvlan.vids_of(nil), 0, "nothing")
			end)
		end
	},
}
