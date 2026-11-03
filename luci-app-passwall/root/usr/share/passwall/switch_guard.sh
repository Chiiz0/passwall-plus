#!/bin/sh
# Sourced after utils.sh. Keep the guard outside TMP_PATH and the normal PSW
# chains: stopping/rebuilding a proxy must never remove the transition barrier.
SWITCH_GUARD_STATE=/tmp/passwall_switch_guard

switch_guard_active() {
	[ -s "$SWITCH_GUARD_STATE" ]
}

switch_guard_needed() {
	switch_guard_active && return 0
	[ "$(config_n_get @global[0] switch_guard 1)" = 1 ] || return 1
	[ "$(config_n_get @global[0] enabled 0)" = 1 ] ||
		[ "$(config_n_get @global[0] acl_enable 0)" = 1 ] ||
		[ "$(get_cache_var ENABLED_DEFAULT_ACL)" = 1 ] ||
		[ "$(get_cache_var ENABLED_ACLS)" = 1 ] ||
		[ "$(get_cache_var GLOBAL_OPENVPN)" = 1 ]
}

switch_guard_nft() {
	# Reject unsupported offload setups before installing a barrier. Errors after
	# installation are handled by the lifecycle controller without dropping state.
	local family table flow reload=0 flows
	flows=$(timeout 5 nft list flowtables) || return 1
	while read -r family table flow; do
		[ -n "$flow" ] || continue
		[ "$family/$table/$flow" = inet/fw4/ft ] || {
			echolog "发现非 fw4 管理的流量卸载表，取消切换。"
			return 1
		}
		reload=1
	done <<EOF
$(printf '%s\n' "$flows" | awk '$1 == "table" {family=$2; table=$3} $1 == "flowtable" {print family, table, $2}')
EOF
	[ "$reload" != 1 ] || timeout 5 ubus call network.interface dump >/dev/null 2>&1 || return 1
	# One transaction, including replacement, so retrying a failed start has no gap.
	{
		echo 'add table inet passwall_switch'
		echo 'flush table inet passwall_switch'
		cat <<'EOF'
add chain inet passwall_switch forward { type filter hook forward priority -10; policy drop; }
add rule inet passwall_switch forward counter drop
add chain inet passwall_switch prerouting { type filter hook prerouting priority -310; policy accept; }
add rule inet passwall_switch prerouting iifname != "lo" meta l4proto { tcp, udp } th dport 53 counter drop
add rule inet passwall_switch prerouting udp sport 68 udp dport 67 accept
add rule inet passwall_switch prerouting udp sport 546 udp dport 547 accept
add rule inet passwall_switch prerouting icmpv6 type { nd-router-solicit, nd-router-advert, nd-neighbor-solicit, nd-neighbor-advert } accept
add rule inet passwall_switch prerouting fib daddr type != local counter drop
add chain inet passwall_switch output { type filter hook output priority -10; policy drop; }
add rule inet passwall_switch output oifname "lo" accept
add rule inet passwall_switch output ct direction reply accept
add rule inet passwall_switch output meta mark 255 accept
EOF
		# Only PassWall's bootstrap/core processes may establish upstream connections.
		printf 'add rule inet passwall_switch output meta skgid %s accept\n' "$DIRECT_GID"
		# TLS-based recovery needs a valid clock. Only the dedicated NTP account
		# can send time synchronization packets; ordinary clients remain blocked.
		local ntp_uid=$(id -u ntp 2>/dev/null)
		case "$ntp_uid" in ''|0|*[!0-9]*) ;; *)
			printf 'add rule inet passwall_switch output meta skuid %s udp dport 123 accept\n' "$ntp_uid"
			;;
		esac
		cat <<'EOF'
add rule inet passwall_switch output udp sport 68 udp dport 67 accept
add rule inet passwall_switch output udp sport 546 udp dport 547 accept
add rule inet passwall_switch output icmpv6 type { nd-router-solicit, nd-neighbor-solicit, nd-neighbor-advert } accept
add rule inet passwall_switch output counter drop
EOF
	} | timeout 10 nft -f - || return 1
	# Cached flows bypass the forward hook. fw4 reload atomically recreates its
	# flowtable (nft has no "flush flowtable" command). Our independent barrier
	# remains installed and prevents new flows from reaching fw4's offload rule.
	if [ "$reload" = 1 ]; then
		timeout 15 fw4 reload || return 1
	fi
	return 0
}

switch_guard_ipt_family() {
	local ipt="$1" family="$2" hook chain
	[ -n "$ipt" ] || return 1
	# iptables-restore commits each table atomically, including retries after a
	# partial failure. Require the complete barrier before tearing down the proxy.
	{
		echo '*filter'
		for chain in PW_SWITCH_FWD PW_SWITCH_OUT PW_SWITCH_DNS; do
			printf ':%s - [0:0]\n-F %s\n' "$chain" "$chain"
		done
		cat <<'EOF'
-A PW_SWITCH_FWD -j DROP
-A PW_SWITCH_DNS ! -i lo -p udp --dport 53 -j DROP
-A PW_SWITCH_DNS ! -i lo -p tcp --dport 53 -j DROP
-A PW_SWITCH_OUT -o lo -j RETURN
-A PW_SWITCH_OUT -m conntrack --ctdir REPLY -j RETURN
-A PW_SWITCH_OUT -m mark --mark 255 -j RETURN
EOF
		printf '%s\n' "-A PW_SWITCH_OUT -m owner --gid-owner $DIRECT_GID -j RETURN"
		local ntp_uid=$(id -u ntp 2>/dev/null)
		case "$ntp_uid" in ''|0|*[!0-9]*) ;; *)
			printf '%s\n' "-A PW_SWITCH_OUT -m owner --uid-owner $ntp_uid -p udp --dport 123 -j RETURN"
			;;
		esac
		if [ "$family" = 4 ]; then
			echo '-A PW_SWITCH_OUT -p udp --sport 68 --dport 67 -j RETURN'
		else
			echo '-A PW_SWITCH_OUT -p udp --sport 546 --dport 547 -j RETURN'
			local kind
			for kind in 133 135 136; do
				printf '%s\n' "-A PW_SWITCH_OUT -p ipv6-icmp --icmpv6-type $kind -j RETURN"
			done
		fi
		echo '-A PW_SWITCH_OUT -j DROP'
		for hook in FORWARD OUTPUT INPUT; do
			case "$hook" in FORWARD) chain=PW_SWITCH_FWD ;; OUTPUT) chain=PW_SWITCH_OUT ;; INPUT) chain=PW_SWITCH_DNS ;; esac
			"$ipt" -w -C "$hook" -j "$chain" 2>/dev/null || printf '%s\n' "-I $hook 1 -j $chain"
		done
		echo COMMIT
		# Block transit before REDIRECT/TPROXY can turn it into local input.
		echo '*raw'
		echo ':PW_SWITCH_PRE - [0:0]'
		echo '-F PW_SWITCH_PRE'
		echo '-A PW_SWITCH_PRE ! -i lo -p udp --dport 53 -j DROP'
		echo '-A PW_SWITCH_PRE ! -i lo -p tcp --dport 53 -j DROP'
		if [ "$family" = 4 ]; then
			echo '-A PW_SWITCH_PRE -p udp --sport 68 --dport 67 -j RETURN'
		else
			echo '-A PW_SWITCH_PRE -p udp --sport 546 --dport 547 -j RETURN'
			for kind in 133 134 135 136; do
				printf '%s\n' "-A PW_SWITCH_PRE -p ipv6-icmp --icmpv6-type $kind -j RETURN"
			done
		fi
		echo '-A PW_SWITCH_PRE -m addrtype ! --dst-type LOCAL -j DROP'
		"$ipt" -w -t raw -C PREROUTING -j PW_SWITCH_PRE 2>/dev/null || echo '-I PREROUTING 1 -j PW_SWITCH_PRE'
		echo COMMIT
	} | timeout 10 "${ipt}-restore" -w 5 --noflush
}

switch_guard_begin() {
	switch_guard_needed || return 0
	local backend
	if switch_guard_active; then
		read -r backend < "$SWITCH_GUARD_STATE"
	elif command -v fw4 >/dev/null 2>&1; then
		backend=nft
	else
		backend=iptables
	fi
	# Record before installation: partial failures also require an explicit retry/stop.
	printf '%s\n' "$backend" > "$SWITCH_GUARD_STATE" || return 1
	case "$backend" in
		nft) switch_guard_nft ;;
		iptables)
			local ipt=$(command -v iptables-legacy || command -v iptables)
			local ip6t=$(command -v ip6tables-legacy || command -v ip6tables)
			switch_guard_ipt_family "$ipt" 4 || return 1
			if [ -e /proc/net/if_inet6 ]; then
				switch_guard_ipt_family "$ip6t" 6 || return 1
			fi
			# fw3 flow offload also bypasses filter. Require a conntrack flush when enabled.
			if [ "$(uci -q get firewall.@defaults[0].flow_offloading)" = 1 ]; then
				conntrack -F >/dev/null 2>&1 || return 1
			fi
			;;
		*) return 1 ;;
	esac || {
		echolog "切换保护安装失败，取消启动/重启，保留现有规则。"
		return 1
	}
	echolog "切换保护已启用：暂停转发和普通本机出网，保留管理应答。"
}

switch_guard_end() {
	local backend ipt hook chain
	if switch_guard_active; then
		read -r backend < "$SWITCH_GUARD_STATE"
	elif command -v fw4 >/dev/null 2>&1; then
		backend=nft
	else
		backend=iptables
	fi
	case "$backend" in
		nft)
			# Listing all tables distinguishes absence from a failed netlink query.
			# Never lose the state marker while the real barrier might still exist.
			local tables
			tables=$(timeout 5 nft list tables) || return 1
			if printf '%s\n' "$tables" | grep -q '^table inet passwall_switch$'; then
				timeout 10 nft delete table inet passwall_switch || return 1
			fi
			tables=$(timeout 5 nft list tables) || return 1
			printf '%s\n' "$tables" | grep -q '^table inet passwall_switch$' && return 1
			;;
		iptables)
			for ipt in "$(command -v iptables-legacy || command -v iptables)" "$(command -v ip6tables-legacy || command -v ip6tables)"; do
				[ -n "$ipt" ] || continue
				[ "$ipt" != "$(command -v ip6tables-legacy || command -v ip6tables)" ] || [ -e /proc/net/if_inet6 ] || continue
				local rules
				rules=$("$ipt" -w 5 -t raw -S) || return 1
				while printf '%s\n' "$rules" | grep -q '^-A PREROUTING -j PW_SWITCH_PRE$'; do
					"$ipt" -w -t raw -D PREROUTING -j PW_SWITCH_PRE || return 1
					rules=$("$ipt" -w 5 -t raw -S) || return 1
				done
				if printf '%s\n' "$rules" | grep -q '^-N PW_SWITCH_PRE$'; then
					"$ipt" -w 5 -t raw -F PW_SWITCH_PRE && "$ipt" -w 5 -t raw -X PW_SWITCH_PRE || return 1
				fi
				for hook in FORWARD OUTPUT INPUT; do
					case "$hook" in FORWARD) chain=PW_SWITCH_FWD ;; OUTPUT) chain=PW_SWITCH_OUT ;; INPUT) chain=PW_SWITCH_DNS ;; esac
					rules=$("$ipt" -w 5 -S) || return 1
					while printf '%s\n' "$rules" | grep -q "^-A $hook -j $chain\$"; do
						"$ipt" -w -D "$hook" -j "$chain" || return 1
						rules=$("$ipt" -w 5 -S) || return 1
					done
					if printf '%s\n' "$rules" | grep -q "^-N $chain\$"; then
						"$ipt" -w 5 -F "$chain" && "$ipt" -w 5 -X "$chain" || return 1
					fi
				done
			done
			;;
		*) return 1 ;;
	esac
	rm -f "$SWITCH_GUARD_STATE"
	echolog "切换保护已解除。"
}

switch_guard_ready() {
	# A successful shell exit alone does not mean background cores survived startup.
	local file pid started current count=0 backend key port sid
	if [ "$(config_n_get @global[0] enabled 0)" = 1 ]; then
		[ "$(get_cache_var ENABLED_DEFAULT_ACL)" = 1 ] || [ "$(get_cache_var GLOBAL_OPENVPN)" = 1 ] || return 1
	fi
	for file in "$TMP_SCRIPT_FUNC_PATH"/*; do
		[ -f "$file" ] || continue
		{ read -r pid; read -r started; } < "$file"
		case "$pid" in ''|*[!0-9]*) return 1 ;; esac
		current=$(get_process_start_time "$pid")
		[ -n "$started" ] && [ "$current" = "$started" ] || return 1
		count=$((count + 1))
	done
	if [ "$(get_cache_var ENABLED_DEFAULT_ACL)" = 1 ] || [ "$(get_cache_var ENABLED_ACLS)" = 1 ] || [ "$(get_cache_var GLOBAL_OPENVPN)" = 1 ]; then
		backend=$(get_cache_var USE_TABLES)
		[ ! -f "$TMP_PATH/firewall_error" ] || return 1
		[ -f "$TMP_PATH/firewall_ready" ] || return 1
		[ -n "$backend" ] || return 1
	fi
	if [ "$(get_cache_var ENABLED_DEFAULT_ACL)" = 1 ]; then
		[ "$count" -gt 0 ] || return 1
	fi
	# Require the actual redirect/DNS listeners, not merely a surviving process.
	for key in $(sed -n 's/^\(ACL_[A-Za-z0-9_]*_\(redir\|dns\)_port\)=.*/\1/p' "$TMP_PATH/var"); do
		port=$(get_cache_var "$key")
		[ "$(check_port_exists "$port")" -gt 0 ] || return 1
	done
	if [ "$(config_n_get @global[0] acl_enable 0)" = 1 ]; then
		for sid in $(uci -q show "$CONFIG" | sed -n 's/^passwall\.\([^.=]*\)=acl_rule$/\1/p'); do
			[ "$(config_n_get "$sid" enabled 0)" = 1 ] || continue
			[ "$(config_n_get "$sid" mode 0)" = 1 ] || continue
			[ -n "$(get_cache_var "ACL_${sid}_redir_port")" ] ||
				[ "$(get_cache_var "ACL_${sid}_openvpn")" = 1 ] ||
				[ "$(get_cache_var "ACL_${sid}_openvpn_global")" = 1 ] || return 1
		done
	fi
	return 0
}

# Shell-based firewall builders historically ignore individual command errors.
# Track failed rule insertions across subshells so a partial ruleset cannot lift
# the guard. Queries, deletion of absent rules, and creating existing chains are
# intentionally excluded.
switch_guard_nft_command() {
	command nft "$@"
	local status=$?
	case "$*" in
		'add rule '*|'insert rule '*)
			[ "$status" -eq 0 ] || printf '%s\n' "$*" >> "$TMP_PATH/firewall_error"
			;;
	esac
	return "$status"
}

switch_guard_ipt_command() {
	"$@"
	local status=$?
	case " $* " in
		*' -A '*|*' -I '*) [ "$status" -eq 0 ] || printf '%s\n' "$*" >> "$TMP_PATH/firewall_error" ;;
	esac
	return "$status"
}
