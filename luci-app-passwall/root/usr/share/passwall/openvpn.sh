#!/bin/sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "${PASSWALL_UTILS_PATH:-${SCRIPT_DIR}/utils.sh}"

OPENVPN_PATH="${PASSWALL_OPENVPN_PATH:-${TMP_PATH}/openvpn}"
OPENVPN_NODE_PATH="${OPENVPN_PATH}/nodes"

valid_id() {
	case "$1" in
		""|*[!A-Za-z0-9_+-]*) return 1 ;;
	esac
}

valid_ipv4() {
	echo "$1" | awk -F. 'NF == 4 {
		for (i = 1; i <= 4; i++) {
			if ($i !~ /^[0-9]+$/ || $i < 0 || $i > 255) exit 1
		}
		exit 0
	} { exit 1 }'
}

normalize_ipv4_cidr() {
	local value="$1" address prefix
	case "$value" in
		*/*)
			address=${value%/*}
			prefix=${value##*/}
			;;
		*)
			address=$value
			prefix=32
			;;
	esac
	valid_ipv4 "$address" || return 1
	case "$prefix" in ""|*[!0-9]*) return 1 ;; esac
	[ "$prefix" -ge 0 ] && [ "$prefix" -le 32 ] || return 1
	printf '%s/%s\n' "$address" "$prefix"
}

node_dir() {
	echo "${OPENVPN_NODE_PATH}/$1"
}

sanitize_profile() {
	local preproxy="$1"
	awk -v preproxy="$preproxy" '
		function directive(line, value) {
			value = line
			sub(/^[ \t]*/, "", value)
			sub(/^--/, "", value)
			sub(/[ \t].*$/, "", value)
			return tolower(value)
		}
		function ipv4_proto(value) {
			value = tolower(value)
			if (value ~ /^udp/) return "udp4"
			if (value ~ /^tcp/) return "tcp4-client"
			return value
		}
		function blocked(value) {
			return value ~ /^(up|down|route-up|route-pre-down|ipchange|client-connect|client-disconnect|learn-address|auth-user-pass-verify|tls-verify|tls-crypt-v2-verify|script-security|daemon|management|management-client|management-external-key|management-external-cert|management-query-passwords|log|log-append|status|status-version|writepid|chroot|cd|setenv|setenv-safe|plugin|config|iproute|dev|dev-type|dev-node|ifconfig-noexec|ifconfig-ipv6|ifconfig-ipv6-push|tun-ipv6|route-noexec|route-nopull|route|route-ipv6|route-method|redirect-gateway|redirect-private|auth-user-pass|http-proxy|http-proxy-option|socks-proxy|socks-proxy-retry|askpass|pkcs11-providers|engine|providers|up-restart|down-pre|proto-force|mark|user|group)$/
		}
		BEGIN { skip_inline = 0; connection = 0 }
		{
			line = $0
			sub(/\r$/, "", line)
			trimmed = line
			sub(/^[ \t]*/, "", trimmed)
			lower = tolower(trimmed)
			if (skip_inline) {
				if (lower ~ "^</" skip_inline ">") skip_inline = 0
				next
			}
			if (lower ~ /^<(auth-user-pass|connection)>/) {
				if (lower ~ /^<auth-user-pass>/) skip_inline = "auth-user-pass"
				else if (preproxy == "1") connection = 1
				else print line
				next
			}
			if (lower ~ /^<\/connection>/) {
				if (preproxy == "1") connection = 0
				else print line
				next
			}
			if (trimmed == "" || trimmed ~ /^[#;]/ || trimmed ~ /^</) {
				print line
				next
			}
			key = directive(trimmed)
			if (blocked(key)) next
			if (key == "proto") {
				if (preproxy == "1") next
				n = split(trimmed, part, /[ \t]+/)
				if (n >= 2) print "proto " ipv4_proto(part[2])
				next
			}
			if (key == "remote") {
				n = split(trimmed, part, /[ \t]+/)
				if (part[2] ~ /:/ || part[2] ~ /^\[/) next
				if (n >= 3) {
					line = "remote " part[2] " " part[3]
					if (preproxy != "1" && n >= 4) line = line " " ipv4_proto(part[4])
					print line
				} else if (n == 2) print "remote " part[2]
				next
			}
			print line
		}
		'
}

resolve_preproxy_ipv4() {
	local host="$1" resolved response candidate
	case "$host" in ""|-*|*[!A-Za-z0-9_.-]*) return 1 ;; esac
	resolved=$(get_host_ip ipv4 "$host" 3)
	if valid_ipv4 "$resolved"; then
		echo "$resolved"
		return 0
	fi

	# Keep remote resolution available when PassWall's local DNS path is not up yet.
	command -v curl >/dev/null 2>&1 || return 1
	command -v jsonfilter >/dev/null 2>&1 || return 1
	response=$(curl -4 -fsS --connect-timeout 3 --max-time 5 \
		-H 'accept: application/dns-json' \
		"https://1.1.1.1/dns-query?name=${host}&type=A" 2>/dev/null) || return 1
	for candidate in $(printf '%s' "$response" | jsonfilter -e '@.Answer[@.type=1].data' 2>/dev/null); do
		if valid_ipv4 "$candidate"; then
			echo "$candidate"
			return 0
		fi
	done
	return 1
}

resolve_preproxy_remotes() {
	local line remote host port resolved
	while IFS= read -r line; do
		case "$line" in
			remote\ *)
				remote=${line#remote }
				host=${remote%% *}
				port=""
				[ "$remote" = "$host" ] || port=${remote#* }
				host=${host#\"}
				host=${host%\"}
				if valid_ipv4 "$host"; then
					resolved=$host
				else
					case "$host" in ""|-*|*[!A-Za-z0-9_.-]*) continue ;; esac
					resolved=$(resolve_preproxy_ipv4 "$host")
					valid_ipv4 "$resolved" || continue
				fi
				printf 'remote %s%s\n' "$resolved" "${port:+ $port}"
				;;
			*) printf '%s\n' "$line" ;;
		esac
	done
}

lan_subnets() {
	local device
	for device in $(get_firewall_zone_devices $(config_n_get @global[0] ipv6_reject_zones lan)); do
		ip -4 route show dev "$device" scope link 2>/dev/null | awk '$1 ~ /^[0-9]+\./ { print $1 }'
	done | awk '!seen[$0]++'
}

append_acl_sources() {
	local output="$1" sid candidates source normalized
	local items=$(uci show ${CONFIG} | grep "=acl_rule" | cut -d '.' -sf 2 | cut -d '=' -sf 1)
	for sid in $items; do
		[ "$(config_n_get "$sid" enabled 0)" = "1" ] || continue
		case "$output" in
			global_sources)
				[ "$(config_n_get "$sid" mode 0)" = "1" ] || continue
				[ "$(config_n_get "$sid" use_global_config 0)" = "1" ] || continue
				;;
			bypass_sources)
				if [ "$(config_n_get "$sid" mode 0)" = "1" ] && [ "$(config_n_get "$sid" use_global_config 0)" = "1" ]; then
					continue
				fi
				;;
			*) return 1 ;;
		esac

		if [ "$(config_n_get "$sid" bind_enable 0)" = "1" ]; then
			candidates=$(config_n_get "$sid" bind_ip)
		else
			candidates=$(config_n_get "$sid" sources)
		fi
		[ -n "$candidates" ] || candidates=$(lan_subnets)
		for source in $candidates; do
			normalized=$(normalize_ipv4_cidr "$source") || continue
			printf '%s|%s\n' "$normalized" "$sid" >> "$output"
		done
	done
}

collect_global_sources() {
	local dir="$1" client="$2" source
	: > "$dir/global_sources"
	: > "$dir/bypass_sources"
	if [ "$client" = "1" ]; then
		for source in $(lan_subnets); do
			normalize_ipv4_cidr "$source" >/dev/null || continue
			printf '%s|default\n' "$source" >> "$dir/global_sources"
		done
	fi
	(
		cd "$dir" || exit 1
		append_acl_sources global_sources
		append_acl_sources bypass_sources
	)
	awk -F'|' '!seen[$1]++' "$dir/global_sources" > "$dir/global_sources.tmp"
	mv "$dir/global_sources.tmp" "$dir/global_sources"
	awk -F'|' '!seen[$1]++' "$dir/bypass_sources" > "$dir/bypass_sources.tmp"
	mv "$dir/bypass_sources.tmp" "$dir/bypass_sources"
}

ensure_killswitch() {
	local table="$1"
	ip -4 route show table "$table" 2>/dev/null | grep -q '^unreachable default.*metric 42760' || \
		ip -4 route add unreachable default metric 42760 table "$table" 2>/dev/null
}

clear_recorded_global_policy() {
	local dir="$1" priority from to iif table
	[ -f "$dir/global_policy_rules" ] || return 0
	while IFS='|' read -r priority from to iif table; do
		case "$priority:$table" in *[!0-9:]*|:*|*:) continue ;; esac
		set -- priority "$priority"
		[ "$from" = "-" ] || set -- "$@" from "$from"
		[ "$to" = "-" ] || set -- "$@" to "$to"
		[ "$iif" = "-" ] || set -- "$@" iif "$iif"
		set -- "$@" fwmark 0/0xffffffff lookup "$table"
		while ip -4 rule del "$@" 2>/dev/null; do :; done
	done < "$dir/global_policy_rules"
	: > "$dir/global_policy_rules"
}

add_global_policy_rule() {
	local dir="$1" priority="$2" from="$3" to="$4" iif="$5" table="$6" record
	record="${priority}|${from}|${to}|${iif}|${table}"
	grep -Fqx "$record" "$dir/global_policy_rules" 2>/dev/null && return 0
	set -- priority "$priority"
	[ "$from" = "-" ] || set -- "$@" from "$from"
	[ "$to" = "-" ] || set -- "$@" to "$to"
	[ "$iif" = "-" ] || set -- "$@" iif "$iif"
	set -- "$@" fwmark 0/0xffffffff lookup "$table"
	ip -4 rule add "$@" 2>/dev/null || return 1
	printf '%s\n' "$record" >> "$dir/global_policy_rules"
}

refresh_global_policy() {
	local node="$1" dir table client localhost allow_lan source sid subnet
	dir=$(node_dir "$node")
	[ -f "$dir/global" ] || return 0
	table=$(cat "$dir/table" 2>/dev/null)
	case "$table" in ""|*[!0-9]*) return 1 ;; esac
	IFS='|' read -r client localhost allow_lan < "$dir/global"
	clear_recorded_global_policy "$dir"
	ensure_killswitch "$table"

	while IFS='|' read -r source sid; do
		normalize_ipv4_cidr "$source" >/dev/null || continue
		add_global_policy_rule "$dir" 105 "$source" - - 254
	done < "$dir/bypass_sources"

	while IFS='|' read -r source sid; do
		normalize_ipv4_cidr "$source" >/dev/null || continue
		if [ "$allow_lan" = "1" ]; then
			for subnet in $(lan_subnets); do
				add_global_policy_rule "$dir" 100 "$source" "$subnet" - 254
			done
		fi
		add_global_policy_rule "$dir" 110 "$source" - - "$table"
	done < "$dir/global_sources"

	if [ "$localhost" = "1" ]; then
		for subnet in $(lan_subnets); do
			add_global_policy_rule "$dir" 100 - "$subnet" lo 254
		done
		add_global_policy_rule "$dir" 111 - - lo "$table"
	fi
}

refresh_policy() {
	local node="$1" dir table priority lan_priority ip allow_lan sid subnet
	dir=$(node_dir "$node")
	[ -d "$dir" ] || return 1
	table=$(cat "$dir/table" 2>/dev/null)
	priority=$(cat "$dir/priority" 2>/dev/null)
	lan_priority=$(cat "$dir/lan_priority" 2>/dev/null)
	case "$table" in ""|*[!0-9]*) return 1 ;; esac
	case "$priority" in ""|*[!0-9]*) return 1 ;; esac
	case "$lan_priority" in ""|*[!0-9]*) return 1 ;; esac
	ensure_killswitch "$table"

	while IFS='|' read -r ip allow_lan sid; do
		valid_ipv4 "$ip" || continue
		while ip -4 rule del priority "$priority" from "$ip/32" lookup "$table" 2>/dev/null; do :; done
		for subnet in $(lan_subnets); do
			while ip -4 rule del priority "$lan_priority" from "$ip/32" to "$subnet" lookup main 2>/dev/null; do :; done
			if [ "$allow_lan" = "1" ]; then
				ip -4 rule add priority "$lan_priority" from "$ip/32" to "$subnet" lookup main 2>/dev/null
			fi
		done
		ip -4 rule add priority "$priority" from "$ip/32" lookup "$table" 2>/dev/null
	done < "$dir/sources"
}

generate_config() {
	local node="$1" preproxy_port="$2" resolve_remote="$3" dir profile username password preproxy tmp resolved_tmp
	dir=$(node_dir "$node")
	profile=$(config_n_get "$node" config)
	username=$(config_n_get "$node" username)
	password=$(config_n_get "$node" password)
	preproxy=0
	[ -n "$preproxy_port" ] && preproxy=1
	tmp="${dir}/client.conf.tmp"

	printf '%s\n' "$profile" | sanitize_profile "$preproxy" > "$tmp" || return 1
	if [ "$preproxy" = "1" ] || [ "$resolve_remote" = "1" ]; then
		resolved_tmp="${tmp}.resolved"
		resolve_preproxy_remotes < "$tmp" > "$resolved_tmp" || return 1
		mv "$resolved_tmp" "$tmp" || return 1
	fi
	grep -Eq '^[[:space:]]*(--)?remote[[:space:]]+' "$tmp" || return 1
	if [ "$preproxy" = "0" ] && ! grep -Eq '^[[:space:]]*(--)?proto[[:space:]]+' "$tmp"; then
		echo "proto udp4" >> "$tmp"
	fi

	cat >> "$tmp" <<-EOF

		# PassWall managed isolation settings
		client
		dev $(cat "$dir/dev")
		dev-type tun
		route-nopull
		route-noexec
		pull-filter ignore "redirect-gateway"
		pull-filter ignore "redirect-private"
		pull-filter ignore "route-ipv6"
		pull-filter ignore "ifconfig-ipv6"
		pull-filter ignore "dhcp-option DNS6"
		script-security 2
		setenv PASSWALL_OPENVPN_NODE $node
		up "/usr/share/passwall/openvpn.sh up"
		down "/usr/share/passwall/openvpn.sh down"
		up-restart
		down-pre
		auth-nocache
		mark 255
		writepid ${dir}/openvpn.pid
	EOF

	if [ -n "$preproxy_port" ]; then
		cat >> "$tmp" <<-EOF
			proto tcp4-client
			socks-proxy 127.0.0.1 $preproxy_port
			socks-proxy-retry
		EOF
	fi

	if [ -n "$username" ] || [ -n "$password" ]; then
		[ -n "$username" ] && [ -n "$password" ] || return 1
		printf '%s\n%s\n' "$username" "$password" > "${dir}/auth.txt"
		chmod 600 "${dir}/auth.txt"
		echo "auth-user-pass ${dir}/auth.txt" >> "$tmp"
	fi

	mv "$tmp" "${dir}/client.conf"
	chmod 600 "${dir}/client.conf"
}

register_acl() {
	local node="$1" sid="$2" ip="$3" slot="$4" allow_lan="$5" preproxy_port="$6"
	local block_only="$7" dir table priority lan_priority dev dns source_line needs_config=0
	valid_id "$node" && valid_id "$sid" && valid_ipv4 "$ip" || return 1
	[ "$(config_n_get "$node" type)" = "OpenVPN" ] || return 1
	case "$preproxy_port" in ""|*[!0-9]*) [ -z "$preproxy_port" ] || return 1 ;; esac
	[ -z "$preproxy_port" ] || { [ "$preproxy_port" -ge 1 ] && [ "$preproxy_port" -le 65535 ]; } || return 1

	dir=$(node_dir "$node")
	if [ ! -d "$dir" ]; then
		case "$slot" in ""|*[!0-9]*) return 1 ;; esac
		[ "$slot" -ge 1 ] && [ "$slot" -le 999 ] || return 1
		mkdir -p "$dir" || return 1
		chmod 700 "$OPENVPN_PATH" "$OPENVPN_NODE_PATH" "$dir" 2>/dev/null
		table=$((20000 + slot))
		# Source rules must run before PassWall/mwan3 mark-based policy rules.
		priority=101
		lan_priority=100
		dev="pswov${slot}"
		dns=$(config_n_get "$node" vpn_dns 1.1.1.1)
		valid_ipv4 "$dns" || dns="1.1.1.1"
		printf '%s\n' "$table" > "$dir/table"
		printf '%s\n' "$priority" > "$dir/priority"
		printf '%s\n' "$lan_priority" > "$dir/lan_priority"
		printf '%s\n' "$dev" > "$dir/dev"
		printf '%s\n' "$dns" > "$dir/dns"
		printf '%s\n' "$preproxy_port" > "$dir/preproxy_port"
		: > "$dir/sources"
		needs_config=1
	fi

	source_line="${ip}|${allow_lan:-1}|${sid}"
	grep -Fqx "$source_line" "$dir/sources" 2>/dev/null || printf '%s\n' "$source_line" >> "$dir/sources"
	refresh_policy "$node"
	[ "$block_only" = "1" ] && return 0
	[ -s "$dir/client.conf" ] || needs_config=1
	[ "$needs_config" = "0" ] || generate_config "$node" "$preproxy_port"
}

register_global() {
	local node="$1" client="$2" localhost="$3" allow_lan="$4" preproxy_port="$5"
	local dir table dev dns config_status=0
	valid_id "$node" || return 1
	[ "$(config_n_get "$node" type)" = "OpenVPN" ] || return 1
	[ "$client" = "0" ] || [ "$client" = "1" ] || return 1
	[ "$localhost" = "0" ] || [ "$localhost" = "1" ] || return 1
	[ "$allow_lan" = "0" ] || [ "$allow_lan" = "1" ] || return 1
	case "$preproxy_port" in ""|*[!0-9]*) [ -z "$preproxy_port" ] || return 1 ;; esac
	[ -z "$preproxy_port" ] || { [ "$preproxy_port" -ge 1 ] && [ "$preproxy_port" -le 65535 ]; } || return 1

	dir=$(node_dir "$node")
	if [ ! -d "$dir" ]; then
		mkdir -p "$dir" || return 1
		chmod 700 "$OPENVPN_PATH" "$OPENVPN_NODE_PATH" "$dir" 2>/dev/null
		printf '20000\n' > "$dir/table"
		printf '101\n' > "$dir/priority"
		printf '100\n' > "$dir/lan_priority"
		printf 'pswov0\n' > "$dir/dev"
		dns=$(config_n_get "$node" vpn_dns 1.1.1.1)
		valid_ipv4 "$dns" || dns="1.1.1.1"
		printf '%s\n' "$dns" > "$dir/dns"
		printf '%s\n' "$preproxy_port" > "$dir/preproxy_port"
		: > "$dir/sources"
	fi

	table=$(cat "$dir/table" 2>/dev/null)
	dev=$(cat "$dir/dev" 2>/dev/null)
	[ "$table" = "20000" ] && [ "$dev" = "pswov0" ] || return 1
	printf '%s|%s|%s\n' "$client" "$localhost" "$allow_lan" > "$dir/global"
	collect_global_sources "$dir" "$client"
	generate_config "$node" "$preproxy_port" 1 || config_status=1
	refresh_global_policy "$node"
	return "$config_status"
}

tunnel_up() {
	local node="$PASSWALL_OPENVPN_NODE" dir table managed_dev
	[ -e "$OPENVPN_PATH/stopping" ] && return 0
	valid_id "$node" || return 1
	dir=$(node_dir "$node")
	table=$(cat "$dir/table" 2>/dev/null)
	managed_dev=$(cat "$dir/dev" 2>/dev/null)
	[ -n "$dev" ] && [ "$dev" = "$managed_dev" ] || return 1
	ip -4 route del default dev "$dev" table "$table" 2>/dev/null
	ip -4 route add default dev "$dev" metric 10 table "$table" 2>/dev/null
	ensure_killswitch "$table"
	refresh_policy "$node"
	refresh_global_policy "$node"
	echolog "OpenVPN 节点[$node]隧道[$dev]已接通。"
}

tunnel_down() {
	local node="$PASSWALL_OPENVPN_NODE" dir table managed_dev
	valid_id "$node" || return 1
	dir=$(node_dir "$node")
	table=$(cat "$dir/table" 2>/dev/null)
	managed_dev=$(cat "$dir/dev" 2>/dev/null)
	[ -n "$managed_dev" ] || return 1
	ip -4 route del default dev "$managed_dev" table "$table" 2>/dev/null
	[ -e "$OPENVPN_PATH/stopping" ] && return 0
	ensure_killswitch "$table"
	echolog "OpenVPN 节点[$node]隧道已断开，设备流量保持阻断。"
}

is_running() {
	local dir pid
	valid_id "$1" || return 1
	dir=$(node_dir "$1")
	pid=$(cat "$dir/openvpn.pid" 2>/dev/null)
	case "$pid" in ""|*[!0-9]*) return 1 ;; esac
	kill -0 "$pid" 2>/dev/null
}

cleanup_node() {
	local node="$1" dir table priority lan_priority dev pid ip allow_lan sid subnet
	valid_id "$node" || return 1
	dir=$(node_dir "$node")
	[ -d "$dir" ] || return 0
	pid=$(cat "$dir/openvpn.pid" 2>/dev/null)
	case "$pid" in ""|*[!0-9]*) ;; *) kill "$pid" 2>/dev/null ;; esac
	priority=$(cat "$dir/priority" 2>/dev/null)
	lan_priority=$(cat "$dir/lan_priority" 2>/dev/null)
	table=$(cat "$dir/table" 2>/dev/null)
	dev=$(cat "$dir/dev" 2>/dev/null)
	clear_recorded_global_policy "$dir"
	while IFS='|' read -r ip allow_lan sid; do
		valid_ipv4 "$ip" || continue
		case "$priority" in
			""|*[!0-9]*) ;;
			*)
				case "$table" in
					""|*[!0-9]*) ;;
					*) while ip -4 rule del priority "$priority" from "$ip/32" lookup "$table" 2>/dev/null; do :; done ;;
				esac
				;;
		esac
		case "$lan_priority" in *[!0-9]*|"") ;;
			*)
				for subnet in $(lan_subnets); do
					while ip -4 rule del priority "$lan_priority" from "$ip/32" to "$subnet" lookup main 2>/dev/null; do :; done
				done
				;;
		esac
	done < "$dir/sources"
	case "$table" in *[!0-9]*|"") ;; *) ip -4 route flush table "$table" 2>/dev/null ;; esac
	case "$dev" in ""|*[!A-Za-z0-9_.-]*) ;; *) ip link delete "$dev" 2>/dev/null ;; esac
}

stop_all() {
	local dir node
	[ -d "$OPENVPN_NODE_PATH" ] || return 0
	: > "$OPENVPN_PATH/stopping"
	for dir in "$OPENVPN_NODE_PATH"/*; do
		[ -d "$dir" ] || continue
		node=${dir##*/}
		cleanup_node "$node"
	done
}

case "$1" in
	resolve-ipv4)
		resolve_preproxy_ipv4 "$2"
		;;
	global)
		shift
		register_global "$@"
		;;
	register)
		shift
		register_acl "$@"
		;;
	block)
		shift
		register_acl "$1" "$2" "$3" "$4" "$5" "" "1"
		;;
	up)
		tunnel_up
		;;
	down)
		tunnel_down
		;;
	running)
		is_running "$2"
		;;
	stop)
		stop_all
		;;
	sanitize-profile)
		sanitize_profile "${2:-0}"
		;;
	*)
		exit 1
		;;
esac
