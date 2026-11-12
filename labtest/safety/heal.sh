#!/bin/sh
# labtest self-heal timer. A TEST TOOL, never shipped. The runner copies it to
# /etc/labtest-heal.sh and knocks (touches /tmp/labtest-knock) every 10 s. No knock
# for LIMIT seconds -> stop openUF, put the saved config back, mark, reboot. Heals once.
# Time is /proc/uptime only: wall time jumps at NTP sync, file dates lie.
# usage: heal.sh arm|boot|tick|watch|heal|disarm
R=${LABTEST_ROOT:-}
LIMIT=${LABTEST_HEAL_LIMIT:-180}
UPF=${LABTEST_UPTIME_FILE:-/proc/uptime}
REBOOT=${LABTEST_REBOOT:-reboot}
SELF=$R/etc/labtest-heal.sh
GOOD=$R/etc/labtest-good.tgz
MARK=$R/etc/labtest-healed
INIT=$R/etc/init.d/labtest-heal
RCD=$R/etc/rc.d/S99labtest-heal
KNOCK=$R/tmp/labtest-knock
LAST=$R/tmp/labtest-last
PID=$R/var/run/labtest-heal.pid
CFG=$R/etc/config

now() { read -r up _ < "$UPF"; echo "${up%.*}"; }

stop_watcher() {
	[ -f "$PID" ] && kill "$(cat "$PID")" 2>/dev/null
	rm -f "$PID"
}

boot() {
	[ -e "$MARK" ] && exit 0
	now > "$LAST"
	[ "$LABTEST_NO_WATCH" = 1 ] && return 0
	stop_watcher
	sh "$0" watch </dev/null >/dev/null 2>&1 &
	echo $! > "$PID"
}

tick() {
	[ -e "$MARK" ] && exit 0
	t=$(now)
	if [ -e "$KNOCK" ]; then
		rm -f "$KNOCK"
		echo "$t" > "$LAST"
	fi
	last=$(cat "$LAST" 2>/dev/null) || last=$t
	[ -n "$last" ] || last=$t
	[ $((t - last)) -gt "$LIMIT" ] && heal
	return 0
}

heal() {
	logger -t labtest-heal "no knock for over $LIMIT s: healing" 2>/dev/null
	# a hung stop must not block the restore: wait a bounded time, then go on
	"$R/etc/init.d/openuf" stop >/dev/null 2>&1 &
	p=$! n=0
	while kill -0 "$p" 2>/dev/null && [ "$n" -lt "${LABTEST_STOP_WAIT:-30}" ]; do
		sleep 1
		n=$((n + 1))
	done
	kill "$p" 2>/dev/null
	"$R/etc/init.d/openuf" disable
	# swap, so a power cut can never leave /etc/config empty
	rm -rf "$CFG.new" "$CFG.bad"
	if mkdir "$CFG.new" && tar xzf "$GOOD" -C "$CFG.new" 2>/dev/null; then
		if mv "$CFG" "$CFG.bad"; then
			if mv "$CFG.new" "$CFG"; then
				rm -rf "$CFG.bad"
			else
				mv "$CFG.bad" "$CFG"
				rm -rf "$CFG.new"
				logger -t labtest-heal "restore failed: /etc/config put back as it was" 2>/dev/null
			fi
		fi
	else
		rm -rf "$CFG.new"
		logger -t labtest-heal "saved config unreadable: /etc/config left as it is" 2>/dev/null
	fi
	# heal once: no boot start, even if the mark below cannot be written (flash full)
	rm -f "$RCD" "$INIT"
	: > "$MARK"
	sync
	$REBOOT
}

case $1 in
arm)
	[ -e "$MARK" ] && { echo "refused: healed mark $MARK exists"; exit 3; }
	if [ ! -e "$GOOD" ]; then
		if ! { tar czf "$GOOD.new" -C "$CFG" . && mv "$GOOD.new" "$GOOD"; }; then
			rm -f "$GOOD.new" 2>/dev/null
			echo "arm failed: could not save $CFG (flash full?)"
			exit 1
		fi
	fi
	if ! { printf '#!/bin/sh /etc/rc.common\nSTART=99\nstart() {\n\t%s boot\n}\n' "/etc/labtest-heal.sh" > "$INIT" &&
		chmod 755 "$INIT" && ln -sf ../init.d/labtest-heal "$RCD"; }; then
		rm -f "$INIT" "$RCD"
		echo "arm failed: could not write $INIT"
		exit 1
	fi
	boot
	;;
boot) boot ;;
tick) tick ;;
watch)
	trap '' HUP
	while :; do
		tick
		sleep 10
	done
	;;
heal) heal ;;
disarm)
	stop_watcher
	rm -f "$RCD" "$INIT" "$GOOD" "$MARK" "$KNOCK" "$LAST" "$SELF"
	sync  # else a power cut soon after can bring the healed state back
	;;
*)
	echo "usage: $0 arm|boot|tick|watch|heal|disarm"
	exit 2
	;;
esac
