#!/usr/bin/env bash
# leak-guard/leaktest.sh
# Check a running client for the leaks that survive a working tunnel.
# Each check prints PASS or FAIL with what was seen:
#   1. exit IP  - the address sites see (must equal EXPECT_IP when it is set)
#   2. DNS      - a filtered name must not come back as the censor's block page
#   3. IPv6     - no IPv6 reaching the internet outside the tunnel
# The kill switch is a crash test and is done by hand (see README).
set -u

usage() {
	cat <<EOF
Usage: ${0##*/}            (settings come from the environment)

  EXPECT_IP=1.2.3.4       your server's IPv4; the exit IP must equal it
  EXPECT_IP6=2001:db8::1  your server's IPv6, if the tunnel carries IPv6
  CANARY=youtube.com      a name your network filters       (default: youtube.com)
  POISON=10.10.34.35      the block-page address it returns; empty = any
                          private or reserved address counts as poisoned
  ECHO_URL / ECHO_URL6    services that print your IP
                          (default: https://api.ipify.org, https://api6.ipify.org)

Exit status: 0 when every check passed.
EOF
}
case ${1-} in -h|--help) usage; exit 0 ;; "") ;; *) usage >&2; exit 2 ;; esac

ECHO_URL=${ECHO_URL:-https://api.ipify.org}
ECHO_URL6=${ECHO_URL6:-https://api6.ipify.org}
EXPECT_IP=${EXPECT_IP:-}
EXPECT_IP6=${EXPECT_IP6:-}
CANARY=${CANARY:-youtube.com}
POISON=${POISON:-}

pass=0; fail=0
ok()   { printf '  [ PASS ] %s\n' "$*"; pass=$((pass + 1)); }
bad()  { printf '  [ FAIL ] %s\n' "$*"; fail=$((fail + 1)); }
sec()  { printf '\n== %s ==\n' "$*"; }
ipv4() { grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1; }
private() { # private / reserved IPv4 = where a block page lives (Iran answers 10.10.34.x)
	local a b
	IFS=. read -r a b _ <<<"$1"
	case $a in
	0|10|127) return 0 ;;
	100) [ "$b" -ge 64 ] && [ "$b" -le 127 ] ;;
	169) [ "$b" -eq 254 ] ;;
	172) [ "$b" -ge 16 ] && [ "$b" -le 31 ] ;;
	192) [ "$b" -eq 168 ] ;;
	*) return 1 ;;
	esac
}
command -v curl >/dev/null 2>&1 || { echo "leaktest: curl is required" >&2; exit 2; }

# 1) exit IP ---------------------------------------------------------------
sec "Exit IP (who the internet thinks you are)"
ip=$(curl -4 -s --max-time 8 "$ECHO_URL" 2>/dev/null | ipv4)
if [ -z "$ip" ]; then
	bad "no answer from $ECHO_URL (tunnel down or the echo service blocked)"
elif [ -n "$EXPECT_IP" ] && [ "$ip" != "$EXPECT_IP" ]; then
	bad "exit IP is $ip, expected $EXPECT_IP"
else
	ok "exit IP = $ip${EXPECT_IP:+ (matches server)}"
fi

# 2) DNS poisoning ---------------------------------------------------------
# A filtered name must not come back as the block page. If it does, the lookup
# reached the ISP's resolver (or was answered on the way) instead of travelling
# inside the tunnel.
sec "DNS not poisoned (lookups travel inside the tunnel)"
# only answer lines count: on a timeout dig prints ";; communications error to
# <resolver>#53", and taking that address as the answer would be a false PASS
if command -v dig >/dev/null 2>&1; then
	ans=$(dig +short +time=4 +tries=1 "$CANARY" A 2>/dev/null | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | head -1)
else
	ans=$(getent ahostsv4 "$CANARY" 2>/dev/null | awk 'NR == 1 { print $1 }')
fi
if [ -z "$ans" ]; then
	bad "could not resolve $CANARY"
elif { [ -n "$POISON" ] && [ "$ans" = "$POISON" ]; } || { [ -z "$POISON" ] && private "$ans"; }; then
	bad "$CANARY -> $ans (the block page) : DNS reached the censor"
else
	ok "$CANARY -> $ans (not the block page)"
fi

# 3) IPv6 egress -----------------------------------------------------------
sec "IPv6 egress (v6 reaching sites outside the tunnel)"
v6=$(curl -6 -s --max-time 6 "$ECHO_URL6" 2>/dev/null | tr -d '[:space:]')
if [ -z "$v6" ]; then
	ok "no IPv6 egress (v6 is carried in-tunnel or disabled)"
elif [ -n "$EXPECT_IP6" ] && [ "$v6" = "$EXPECT_IP6" ]; then
	ok "IPv6 exit = $v6 (matches server)"
else
	bad "IPv6 egress = $v6 (v6 reaches the internet${EXPECT_IP6:+, expected $EXPECT_IP6})"
fi

# The kill switch is a crash test, not a probe: with strict_route the routing
# rules outlive a killed sing-box, so traffic fails closed instead of leaking.
# Check it by hand: sudo pkill -9 sing-box, then curl anything - it must fail.

printf '\n== Result: %d passed, %d failed ==\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
