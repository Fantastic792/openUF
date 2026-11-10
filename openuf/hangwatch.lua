--[[
	hangwatch.lua -- kill a command the inform daemon is stuck on.

	The daemon is one blocking Lua 5.1 loop, and every os.execute / io.popen
	it makes can hang for good: iw, lldpctl, swconfig and nft wait on a kernel
	or a socket with no time limit of their own. While the call
	waits, nothing else runs: no inform, no STUN, no mesh failover, and the
	controller marks the AP disconnected until someone restarts the service.

	Stock OpenWrt has no `timeout` applet (checked on 25.12.6), so the
	commands cannot be wrapped. Instead the daemon starts ONE background
	POSIX-sh loop at startup. Every POLL_S seconds it lists the daemon's
	direct children in /proc; a child that has lived LIMIT_S (the same pid
	and start time on every poll) gets the whole process tree under it sent
	TERM, and whatever of that tree is still the same process on the next
	poll gets KILL. The pipe or shell the daemon was blocked on then ends,
	and the loop carries on. syslog gets one line with the names of what was
	stopped -- names only, never the command line, which can carry a
	passphrase.

	Not covered: a process stuck inside the kernel (no signal reaches it), and
	one that detached itself while still holding the pipe.

	Nothing is added to the heartbeat path: the Lua side runs one command at
	startup. The loop ends by itself when the daemon does (or its pid is
	reused). `touch /etc/openuf/no-hangwatch` keeps it from starting.
]]

local M = {}
local util = package.loaded["openuf.util"]
	or assert(loadfile("util.lua") or loadfile("openuf/util.lua"))()

M.LIMIT_S  = 60
M.POLL_S   = 5
M.OFF_FILE = "/etc/openuf/no-hangwatch"

M._exec      = os.execute
M._read_file = util.read_file
function M._exists(path)
	local f = io.open(path, "r")
	if not f then return false end
	f:close()
	return true
end

-- Runs under busybox ash and dash. It is spliced into sh -c '...', so it
-- must never contain a single quote.
M.SCRIPT = [==[
D=$1; POLL=$2; MAX=$3
stat_of() { # sets N (name), P (ppid), S (start time) of pid $1; fails when it is gone
	local l; N=; P=; S=
	{ read -r l < /proc/$1/stat; } 2>/dev/null || return 1
	N=${l#*(}; N=${N%)*}
	l=${l##*) }; set -- $l; P=$2; S=${20}
}
stat_of $D || exit 0; D0=$S
seen=; doomed=
while :; do
	sleep $POLL
	# Sent TERM on the last poll and still the same process: KILL. Before the
	# daemon check, so a daemon that ended meanwhile leaves nothing behind.
	for m in $doomed; do
		stat_of ${m%%.*} && [ "$S" = "${m#*.}" ] && kill -KILL ${m%%.*} 2>/dev/null
	done
	stat_of $D && [ "$S" = "$D0" ] || exit 0 # daemon gone, or its pid reused
	doomed=; new=
	for d in /proc/[0-9]*; do
		p=${d#/proc/}; stat_of $p || continue
		[ "$P" = "$D" ] && [ "$p" != "$$" ] || continue
		k=$p.$S; c=1
		for e in $seen; do [ "${e%%:*}" = "$k" ] && c=$(( ${e##*:} + 1 )); done
		new="$new $k:$c"
		[ $c -eq $MAX ] || continue
		tree=$p; names=$N; marks=$k; grew=1
		while [ $grew = 1 ]; do grew=0
			for d2 in /proc/[0-9]*; do
				q=${d2#/proc/}; stat_of $q || continue
				[ "$q" != "$$" ] || continue
				case " $tree " in *" $q "*) continue;; esac
				case " $tree " in *" $P "*)
					tree="$tree $q"; names="$names $N"; marks="$marks $q.$S"; grew=1;;
				esac
			done
		done
		doomed="$doomed $marks"
		if command -v logger >/dev/null; then
			logger -t openuf "hangwatch: a command ran about $(( c * POLL )) s, stopping it: $names (pids $tree)"
		fi
		kill -TERM $tree 2>/dev/null
	done
	seen=$new
done
]==]

-- The daemon's own pid: the first field of /proc/self/stat (Lua 5.1 has no
-- getpid).
function M.self_pid()
	local s = M._read_file("/proc/self/stat")
	if type(s) ~= "string" then return nil end
	local n = tonumber(s:match("^(%d+) "))
	if n and n >= 1 and math.floor(n) == n then return n end
	return nil
end

local function posint(x)
	return type(x) == "number" and x >= 1 and math.floor(x) == x
end

-- The exact line for os.execute. Only digits are spliced in, so no pushed
-- or read value can reach the shell as anything else.
function M.command(pid, poll, polls)
	if not (posint(pid) and posint(poll) and posint(polls)) then return nil end
	return string.format("sh -c '%s' openuf-hangwatch %.0f %.0f %.0f </dev/null >/dev/null 2>&1 &",
		M.SCRIPT, pid, poll, polls)
end

-- opts (all optional): limit, poll (seconds), pid. true when the command
-- ran; false, reason when nothing was started.
function M.start(opts)
	opts = opts or {}
	if M._exists(M.OFF_FILE) then return false, M.OFF_FILE .. " exists" end
	local pid = opts.pid or M.self_pid()
	if not pid then return false, "own pid unknown" end
	local limit, poll = opts.limit or M.LIMIT_S, opts.poll or M.POLL_S
	if type(limit) ~= "number" or limit <= 0 then return false, "bad limit" end
	if type(poll) ~= "number" or poll <= 0 then return false, "bad poll" end
	local polls = math.max(2, math.ceil(limit / poll))
	local cmd = M.command(pid, math.ceil(poll), polls)
	if not cmd then return false, "bad arguments" end
	M._exec(cmd)
	return true
end

return M
