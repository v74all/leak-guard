#!/usr/bin/env bash
# leak-guard/harden.sh
# Wrap a working proxy in a sing-box client config that does not leak:
#   - a TUN interface with auto_route + strict_route takes every packet, so
#     nothing goes around the tunnel. If sing-box dies, its routing rules stay
#     and traffic fails closed instead of leaking (kill switch).
#   - DNS is hijacked into sing-box and resolved over DoH through the proxy,
#     so the network can neither see nor poison your lookups.
#   - IPv6 is dropped (default), so v6 never reaches a site outside the tunnel.
#   - Iranian sites (geoip-ir / geosite-ir) and private ranges go direct, so
#     banks and services that refuse foreign IPs keep working.
# The config is written and checked with `sing-box check`. It is never started.
set -euo pipefail

prog=${0##*/}
version=1.0.0
rules_url=https://raw.githubusercontent.com/Chocolate4U/Iran-sing-box-rules/rule-set

die() { printf '%s: %s\n' "$prog" "$*" >&2; exit 1; }
warn() { printf '%s: warning: %s\n' "$prog" "$*" >&2; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing dependency: $1"; }

usage() {
	cat <<EOF
Usage:
  $prog --link 'vless://...'        [options]
  $prog --link 'hysteria2://...'    [options]
  $prog --socks 127.0.0.1:10808     [options]   (chain to a local Xray client, e.g. XHTTP)
  $prog --outbound outbound.json    [options]

Proxy (one of):
      --link URI          VLESS share link (tcp, ws, grpc, httpupgrade, http;
                          reality or tls) or Hysteria2 share link (obfs,
                          port hopping)
      --socks HOST:PORT   SOCKS5 port of a client running next to sing-box
      --process NAME      with --socks: that client's process name; its own
                          traffic goes around the tunnel (default: xray,
                          repeat for more names)
      --server NAME       with --socks: your server's domain name, looked up
                          outside the tunnel (repeat for more names)
      --outbound FILE     any sing-box outbound as JSON (tag becomes "proxy")

Options:
  -o, --out FILE          output config                (default: ./sb-hardened.json)
      --doh URL           DoH resolver, used through the proxy
                                                       (default: https://1.1.1.1/dns-query)
      --direct-dns X      resolver for Iranian sites and your server's own
                          name: auto, local, dhcp or an IP   (default: auto =
                          dhcp behind a local stub such as systemd-resolved,
                          else local)
      --ipv6 on|off       carry IPv6 in the tunnel or drop it   (default: off)
      --no-ir-direct      send Iranian sites through the proxy too
      --rules DIR         use geoip-ir.srs / geosite-ir.srs from DIR instead of
                          downloading them through the proxy on first start
      --tun-stack S       system, gvisor or mixed      (default: system)
      --no-auto-redirect  Linux: do not use nftables auto_redirect
      --no-check          do not run sing-box check
  -h, --help
  -V, --version
EOF
}

val() { [ -n "${2-}" ] || die "$1 needs a value (see --help)"; printf '%s' "$2"; }

link=""; socks=""; outbound_file=""; procs=(); servers=()
out=./sb-hardened.json; doh=${LEAKGUARD_DOH:-https://1.1.1.1/dns-query}; direct_dns=auto
ipv6=off; ir_direct=1; rules_dir=""; tun_stack=system; auto_redirect=1; do_check=1

while [ $# -gt 0 ]; do
	case $1 in
	--link) link=$(val "$@"); shift 2 ;;
	--socks) socks=$(val "$@"); shift 2 ;;
	--process) procs+=("$(val "$@")"); shift 2 ;;
	--server) servers+=("$(val "$@")"); shift 2 ;;
	--outbound) outbound_file=$(val "$@"); shift 2 ;;
	-o|--out) out=$(val "$@"); shift 2 ;;
	--doh) doh=$(val "$@"); shift 2 ;;
	--direct-dns) direct_dns=$(val "$@"); shift 2 ;;
	--ipv6) ipv6=$(val "$@"); shift 2 ;;
	--ir-direct) ir_direct=1; shift ;;
	--no-ir-direct) ir_direct=0; shift ;;
	--rules) rules_dir=$(val "$@"); shift 2 ;;
	--tun-stack) tun_stack=$(val "$@"); shift 2 ;;
	--no-auto-redirect) auto_redirect=0; shift ;;
	--no-check) do_check=0; shift ;;
	-h|--help) usage; exit 0 ;;
	-V|--version) echo "leak-guard $version"; exit 0 ;;
	*) die "unknown argument: $1 (see --help)" ;;
	esac
done

need jq
n=0
for x in "$link" "$socks" "$outbound_file"; do [ -z "$x" ] || n=$((n + 1)); done
[ "$n" -eq 1 ] || { usage >&2; die "give exactly one of --link, --socks, --outbound"; }
[ ${#procs[@]} -eq 0 ] || [ -n "$socks" ] || die "--process only goes with --socks"
[ -z "$socks" ] || [ ${#procs[@]} -gt 0 ] || procs=(xray)
[ ${#servers[@]} -eq 0 ] || [ -n "$socks" ] || die "--server only goes with --socks (a link already names the server)"
case $ipv6 in on|off) ;; *) die "--ipv6 takes on or off" ;; esac
case $tun_stack in system|gvisor|mixed) ;; *) die "--tun-stack takes system, gvisor or mixed" ;; esac
case $doh in https://?*) ;; *) die "--doh needs an https:// URL" ;; esac
case $direct_dns in
auto)
	# Behind a local stub (systemd-resolved 127.0.0.53, NetworkManager's dnsmasq) the stub forwards from its own
	# process, the tunnel hijacks that query back into sing-box and a server given by name never resolves (lab
	# test, Ubuntu-style resolved). dhcp asks the network for its DNS servers and queries them from sing-box itself.
	ns=$(awk '$1 == "nameserver" { print $2; exit }' /etc/resolv.conf 2>/dev/null || true)
	case $ns in 127.*|::1) direct_dns=dhcp ;; *) direct_dns=local ;; esac
	;;
local|dhcp) ;;
*) [[ $direct_dns =~ ^[0-9.]+$ || $direct_dns == *:* ]] || die "--direct-dns takes auto, local, dhcp or an IP address" ;;
esac
if [ -n "$rules_dir" ] && [ "$ir_direct" = 1 ]; then
	for f in geoip-ir.srs geosite-ir.srs; do [ -f "$rules_dir/$f" ] || die "no $f in $rules_dir"; done
	rules_dir=$(cd "$rules_dir" && pwd)
fi

# ---- share link helpers ----
urldecode() { local s=${1//\\/\\\\}; printf '%b' "${s//%/\\x}"; }
qget() { # qget <query> <key> -> url-decoded value, or nothing
	local kv kvs
	IFS='&' read -ra kvs <<<"$1"
	for kv in "${kvs[@]}"; do
		if [ "${kv%%=*}" = "$2" ]; then urldecode "${kv#*=}"; return; fi
	done
}
split_hostport() { # split_hostport <host:port | [v6]:port> -> sets host, port
	case $1 in
	\[*\]:*) host=${1%%]:*}; host=${host#[}; port=${1##*]:} ;;
	*:*) host=${1%:*}; port=${1##*:} ;;
	*) die "no port in '$1'" ;;
	esac
	[ -n "$host" ] || die "no host in '$1'"
}

vless_outbound() { # <host> <port> <uuid> <query>
	local h=$1 p=$2 id=$3 q=$4 type sec flow sni fp pbk sid alpn path thost svc ins ed tr=null
	type=$(qget "$q" type); type=${type:-tcp}
	sec=$(qget "$q" security); flow=$(qget "$q" flow); sni=$(qget "$q" sni); fp=$(qget "$q" fp)
	pbk=$(qget "$q" pbk); sid=$(qget "$q" sid); alpn=$(qget "$q" alpn)
	path=$(qget "$q" path); thost=$(qget "$q" host); svc=$(qget "$q" serviceName)
	ins=$(qget "$q" allowInsecure); [ -n "$ins" ] || ins=$(qget "$q" insecure)
	case $type in
	tcp|raw)
		[ "$(qget "$q" headerType)" != http ] || die "tcp with headerType=http is not supported"
		;;
	ws)
		ed=""
		case $path in *\?ed=*) ed=${path##*\?ed=}; ed=${ed%%&*}; path=${path%%\?*} ;; esac
		tr=$(jq -nc --arg p "${path:-/}" --arg h "$thost" --arg ed "$ed" '{type:"ws", path:$p}
			+ (if $h != "" then {headers:{Host:$h}} else {} end)
			+ (if $ed != "" then {max_early_data:($ed|tonumber), early_data_header_name:"Sec-WebSocket-Protocol"} else {} end)')
		;;
	grpc) tr=$(jq -nc --arg s "$svc" '{type:"grpc", service_name:$s}') ;;
	httpupgrade) tr=$(jq -nc --arg p "${path:-/}" --arg h "$thost" '{type:"httpupgrade", path:$p} + (if $h != "" then {host:$h} else {} end)') ;;
	http|h2) tr=$(jq -nc --arg p "${path:-/}" --arg h "$thost" '{type:"http", path:$p} + (if $h != "" then {host:[$h]} else {} end)') ;;
	xhttp|splithttp)
		die "sing-box has no XHTTP transport. Keep your Xray client for the server and chain to its SOCKS port: $prog --socks 127.0.0.1:10808 (see README)"
		;;
	*) die "unsupported VLESS transport: type=$type" ;;
	esac
	[ -z "$flow" ] || [ "$type" = tcp ] || [ "$type" = raw ] || die "flow=$flow only works with type=tcp"
	case $sec in
	reality) [ -n "$pbk" ] && [ -n "$sni" ] || die "a reality link needs pbk and sni" ;;
	tls|none|"") ;;
	*) die "unsupported security=$sec" ;;
	esac
	[[ $p =~ ^[0-9]+$ ]] || die "bad port: $p"
	jq -n --arg h "$h" --argjson p "$p" --arg id "$id" --arg flow "$flow" --arg sec "$sec" --arg sni "$sni" \
		--arg fp "$fp" --arg pbk "$pbk" --arg sid "$sid" --arg alpn "$alpn" --arg ins "$ins" --argjson tr "$tr" '
		{ type:"vless", tag:"proxy", server:$h, server_port:$p, uuid:$id }
		+ (if $flow != "" then {flow:$flow} else {} end)
		+ (if $sec == "reality" then
			{ tls:{ enabled:true, server_name:$sni, utls:{enabled:true, fingerprint:(if $fp == "" then "chrome" else $fp end)},
			        reality:{enabled:true, public_key:$pbk, short_id:$sid} } }
		  elif $sec == "tls" then
			{ tls:({ enabled:true, server_name:(if $sni == "" then $h else $sni end), insecure:($ins == "1" or $ins == "true") }
			       + (if $alpn != "" then {alpn:($alpn|split(","))} else {} end)
			       + (if $fp != "" then {utls:{enabled:true, fingerprint:$fp}} else {} end)) }
		  else {} end)
		+ (if $tr != null then {transport:$tr} else {} end)'
}

hy2_outbound() { # <host> <port spec: 443 | 443,50001-60000> <auth> <query>
	local h=$1 spec=$2 auth=$3 q=$4 main extra mport sni ins obfs opw r list=() ranges=()
	main=${spec%%,*}; extra=""
	[ "$main" = "$spec" ] || extra=${spec#*,}
	[[ $main =~ ^[0-9]+$ ]] || die "bad port in link: $main"
	mport=$(qget "$q" mport)
	IFS=, read -ra list <<<"$extra${extra:+${mport:+,}}$mport"
	for r in "${list[@]}"; do
		[ -n "$r" ] || continue
		[[ $r =~ ^[0-9]+(-[0-9]+)?$ ]] || die "bad port range in link: $r"
		case $r in *-*) ranges+=("${r/-/:}") ;; *) ranges+=("$r:$r") ;; esac
	done
	sni=$(qget "$q" sni); ins=$(qget "$q" insecure); obfs=$(qget "$q" obfs); opw=$(qget "$q" obfs-password)
	[ -z "$obfs" ] || [ "$obfs" = salamander ] || die "unsupported obfs=$obfs"
	[ -z "$obfs" ] || [ -n "$opw" ] || die "obfs=salamander without obfs-password"
	[ -z "$(qget "$q" pinSHA256)" ] || warn "pinSHA256 is a Hysteria-only option that sing-box cannot use; the server certificate is not pinned. A real certificate on the server (insecure=0) avoids this."
	jq -n --arg h "$h" --arg main "$main" --arg auth "$auth" --arg sni "$sni" --arg ins "$ins" \
		--arg obfs "$obfs" --arg opw "$opw" --argjson r "$(jq -nc '$ARGS.positional' --args "${ranges[@]}")" '
		{ type:"hysteria2", tag:"proxy", server:$h, password:$auth,
		  tls:{ enabled:true, server_name:(if $sni == "" then $h else $sni end), insecure:($ins == "1" or $ins == "true") } }
		+ (if ($r|length) > 0 then {server_ports:([$main + ":" + $main] + $r), hop_interval:"30s"}
		   else {server_port:($main|tonumber)} end)
		+ (if $obfs != "" then {obfs:{type:"salamander", password:$opw}} else {} end)'
}

outbound_from_link() {
	local url=$1 scheme rest query="" hostpart
	scheme=${url%%://*}; rest=${url#*://}; rest=${rest%%#*}
	[ "$scheme" != "$url" ] || die "not a share link: $url"
	case $rest in *\?*) query=${rest#*\?}; rest=${rest%%\?*} ;; esac
	rest=${rest%/}
	case $rest in *@*) ;; *) die "no user part (uuid / password) in the link" ;; esac
	hostpart=${rest##*@}
	case $scheme in
	vless)
		split_hostport "$hostpart"
		vless_outbound "$host" "$port" "$(urldecode "${rest%@*}")" "$query"
		;;
	hysteria2|hy2)
		split_hostport "$hostpart"
		hy2_outbound "$host" "$port" "$(urldecode "${rest%@*}")" "$query"
		;;
	*) die "unsupported link scheme: $scheme (vless, hysteria2; anything else: --outbound or --socks)" ;;
	esac
}

if [ -n "$link" ]; then
	proxy_ob=$(outbound_from_link "$link")
elif [ -n "$socks" ]; then
	split_hostport "$socks"
	[[ $port =~ ^[0-9]+$ ]] || die "bad port: $port"
	proxy_ob=$(jq -n --arg h "$host" --argjson p "$port" '{type:"socks", tag:"proxy", server:$h, server_port:$p, version:"5"}')
else
	[ -f "$outbound_file" ] || die "no such file: $outbound_file"
	jq -e 'type == "object" and has("type")' "$outbound_file" >/dev/null 2>&1 || die "$outbound_file is not a sing-box outbound (JSON object with a type)"
	proxy_ob=$(jq '.tag = "proxy"' "$outbound_file")
fi

# ---- assemble the config ----
# remote rule-sets: sing-box 1.14 replaced download_detour with http_client (1.12 / 1.13 only know the old one)
sbv=$(sing-box version 2>/dev/null | awk 'NR == 1 { print $3 }' || true)
case $sbv in
1.[0-9].*|1.1[01].*) die "sing-box $sbv is too old for this config, 1.12 or newer is needed" ;;
1.12.*|1.13.*) dl='{download_detour:"proxy"}' ;;
*) dl='{http_client:{detour:"proxy"}}' ;;
esac
mkdir -p "$(dirname "$out")"
outdir=$(cd "$(dirname "$out")" && pwd)
jq -n \
	--argjson dl "$(jq -nc "$dl")" \
	--argjson proxy "$proxy_ob" \
	--arg doh "$doh" \
	--arg ddns "$direct_dns" \
	--arg stack "$tun_stack" \
	--argjson v6 "$([ "$ipv6" = on ] && echo true || echo false)" \
	--argjson ir "$ir_direct" \
	--argjson redirect "$auto_redirect" \
	--arg rules "$rules_dir" \
	--arg url "$rules_url" \
	--arg cache "$outdir/leak-guard-cache.db" \
	--argjson procs "$(jq -nc '$ARGS.positional' --args "${procs[@]}")" \
	--argjson servers "$(jq -nc '$ARGS.positional' --args "${servers[@]}")" '
	($doh | sub("^https://"; "") | sub("/.*$"; "")) as $hp
	| ($doh | sub("^https://[^/]+"; "") | if . == "" then "/dns-query" else . end) as $path
	| (if $rules == "" then
		[ "geoip-ir", "geosite-ir" ] | map({ type:"remote", tag:., format:"binary", url:($url + "/" + . + ".srs"),
		                                     update_interval:"7d" } + $dl)
	   else
		[ "geoip-ir", "geosite-ir" ] | map({ type:"local", tag:., format:"binary", path:($rules + "/" + . + ".srs") })
	   end) as $sets
	| {
	  log: { level:"warn", timestamp:true },
	  dns: {
	    servers: [
	      ({ type:"https", tag:"dns-proxy", server:($hp | sub(":[0-9]+$"; "")), path:$path, detour:"proxy" }
	       + (if ($hp | test(":[0-9]+$")) then {server_port:($hp | sub("^.*:"; "") | tonumber)} else {} end)),
	      (if $ddns == "local" or $ddns == "dhcp" then { type:$ddns, tag:"dns-direct" }
	       else { type:"udp", tag:"dns-direct", server:$ddns } end)
	    ],
	    rules: ((if ($servers | length) > 0 then [ { domain:$servers, server:"dns-direct" } ] else [] end)
	            + (if $ir == 1 then [ { rule_set:["geosite-ir"], server:"dns-direct" } ] else [] end)),
	    final: "dns-proxy",
	    strategy: (if $v6 then "prefer_ipv4" else "ipv4_only" end)
	  },
	  inbounds: [
	    { type:"tun", tag:"tun-in", interface_name:"tun0",
	      address: (["172.19.0.1/30"] + (if $v6 then ["fdfe:dcba:9876::1/126"] else [] end)),
	      auto_route:true, strict_route:true, stack:$stack }
	    + (if $redirect == 1 then {auto_redirect:true} else {} end)
	  ],
	  outbounds: [ $proxy, { type:"direct", tag:"direct" } ],
	  # sing-box tags its own connections with 0x2024 (8228) for killswitch.sh: auto_redirect does it by itself
	  # (and refuses default_mark next to it), without auto_redirect default_mark does it
	  route: ((if $redirect == 1 then {} else {default_mark:8228} end) + {
	    auto_detect_interface: true,
	    default_domain_resolver: "dns-direct",
	    rule_set: (if $ir == 1 then $sets else [] end),
	    rules: (
	      (if ($procs | length) > 0 then [ { process_name:$procs, action:"route", outbound:"direct" } ] else [] end)
	      + [ { action:"sniff" }, { protocol:"dns", action:"hijack-dns" } ]
	      + (if $v6 then [] else [ { ip_version:6, action:"reject" } ] end)
	      + [ { ip_is_private:true, action:"route", outbound:"direct" } ]
	      + (if $ir == 1 then [ { rule_set:["geoip-ir", "geosite-ir"], action:"route", outbound:"direct" } ] else [] end)
	    ),
	    final: "proxy"
	  })
	}
	+ (if $ir == 1 and $rules == "" then { experimental:{ cache_file:{ enabled:true, path:$cache } } } else {} end)' >"$out"

printf '%s: wrote %s\n' "$prog" "$out"
# lab test: with auto_redirect a killed sing-box still blocks TCP; without it every protocol leaks on a crash
[ "$auto_redirect" = 1 ] || warn "without auto_redirect a crashed sing-box leaks; use killswitch.sh"
if [ "$do_check" = 1 ]; then
	need sing-box
	sing-box check -c "$out" && printf '%s: sing-box check OK\n' "$prog"
fi
