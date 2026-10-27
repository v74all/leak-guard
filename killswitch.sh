#!/usr/bin/env bash
# leak-guard/killswitch.sh
# Firewall kill switch for the hardened sing-box client (Linux, nftables).
# strict_route + auto_redirect keep TCP from leaking when sing-box crashes, but
# UDP (QUIC, WebRTC's STUN) and ICMP still go out on the normal route. This adds
# an nftables table that lets this machine send only:
#   - into the tunnel interface and loopback
#   - sing-box's own connections (they carry its routing mark)
#   - DHCP, IPv6 neighbour discovery and the local network (but no DNS to it)
# Everything else is dropped, whether sing-box is running or not. While it is
# on and sing-box is stopped, this machine has no internet: that is the point.
set -euo pipefail

prog=${0##*/}
table=leak_guard
die() { printf '%s: %s\n' "$prog" "$*" >&2; exit 1; }

usage() {
	cat <<EOF
Usage: sudo $prog on [--tun NAME] [--mark MARK] [--no-lan]
       sudo $prog off
       sudo $prog status

  --tun NAME    tunnel interface         (default: tun0, as harden.sh writes it)
  --mark MARK   sing-box's routing mark  (default: 0x2024 = route.default_mark 8228 in harden.sh)
  --no-lan      do not allow the local network (router page, printer, NAS)
EOF
}

cmd=${1-}
[ $# -eq 0 ] || shift
tun=tun0; mark=0x2024; lan=1
while [ $# -gt 0 ]; do
	case $1 in
	--tun) [ -n "${2-}" ] || die "--tun needs a value"; tun=$2; shift 2 ;;
	--mark) [ -n "${2-}" ] || die "--mark needs a value"; mark=$2; shift 2 ;;
	--no-lan) lan=0; shift ;;
	-h|--help) usage; exit 0 ;;
	*) die "unknown argument: $1 (see --help)" ;;
	esac
done

case $cmd in
on|off|status) ;;
-h|--help) usage; exit 0 ;;
*) usage >&2; exit 2 ;;
esac
command -v nft >/dev/null 2>&1 || die "nft not found (sudo apt install nftables)"
[ "$(id -u)" -eq 0 ] || die "run it as root (sudo)"

case $cmd in
on)
	[[ $tun =~ ^[A-Za-z0-9_.-]{1,15}$ ]] || die "bad interface name: $tun"
	[[ $mark =~ ^(0x[0-9a-fA-F]+|[0-9]+)$ ]] || die "bad mark: $mark"
	lan_rules=""
	if [ "$lan" = 1 ]; then
		lan_rules="ip daddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16 } accept
		ip6 daddr { fe80::/10, fc00::/7 } accept"
	fi
	# create + delete first, so "on" twice replaces the table instead of failing.
	# postrouting, not output: sing-box moves packets into the tunnel after the output hook (a DNAT for DNS, a
	# redirect for TCP, a routing mark for UDP depending on the system), and only here is the interface the real
	# one. With sing-box dead, tun0 is gone and those packets fall through to the drop. Forwarded traffic
	# (containers, VMs) does not come from a local address and is left alone.
	nft -f - <<EOF
table inet $table
delete table inet $table
table inet $table {
	chain postrouting {
		type filter hook postrouting priority filter; policy accept;
		fib saddr type != local accept
		oifname { "lo", "$tun" } accept
		meta mark $mark accept
		udp sport 68 udp dport 67 accept
		udp sport 546 udp dport 547 accept
		icmpv6 type { nd-router-solicit, nd-neighbor-solicit, nd-neighbor-advert } accept
		meta l4proto { tcp, udp } th dport 53 drop
		$lan_rules
		drop
	}
}
EOF
	if [ "$lan" = 1 ]; then where="the tunnel ($tun), sing-box itself and the local network"
	else where="the tunnel ($tun) and sing-box itself"; fi
	printf '%s: on - only %s can reach the network\n' "$prog" "$where"
	;;
off)
	if nft delete table inet "$table" 2>/dev/null; then
		printf '%s: off - normal network\n' "$prog"
	else
		printf '%s: was not on\n' "$prog"
	fi
	;;
status)
	if nft list table inet "$table" >/dev/null 2>&1; then
		printf '%s: on\n' "$prog"
		nft list table inet "$table"
	else
		printf '%s: off\n' "$prog"
	fi
	;;
esac
