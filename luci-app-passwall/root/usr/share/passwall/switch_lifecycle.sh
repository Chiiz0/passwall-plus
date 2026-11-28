#!/bin/sh
# All mutations below run under the service lock. Request IDs are written before
# taking that lock so a stop/new switch can cancel a long-running older request.
SWITCH_DIR=/tmp/passwall_switch
SWITCH_SAVE=/etc/passwall/.switch

switch_write() {
	local key="$1" value="$2" tmp
	umask 077
	mkdir -p "$SWITCH_DIR" || return 1
	chmod 700 "$SWITCH_DIR"
	tmp=$(mktemp "$SWITCH_DIR/.write.XXXXXX") || return 1
	printf '%s\n' "$value" > "$tmp" && mv -f "$tmp" "$SWITCH_DIR/$key"
}

switch_read() { cat "$SWITCH_DIR/$1" 2>/dev/null; }
switch_now() { cut -d. -f1 /proc/uptime; }
switch_current() { [ "$(switch_read request)" = "$SWITCH_REQUEST" ]; }
switch_result() { switch_write result "$1"; }
switch_phase() { switch_write phase "$1"; }
switch_settled() {
	switch_current || return 1
	switch_write handled "$SWITCH_REQUEST"
	switch_phase idle
	switch_result "$1"
	switch_write attempts 0
	case "$SWITCH_REQUEST" in *' boot') touch "${LOCK_PATH}/${CONFIG}_ready.lock" ;; esac
}

switch_export() {
	local tmp
	tmp=$(mktemp "$SWITCH_DIR/.config.XXXXXX") || return 1
	if uci -q export passwall > "$tmp"; then
		sed '/^package /d' "$tmp"
		rm -f "$tmp"
	else
		rm -f "$tmp"
		return 1
	fi
}

switch_digest_file() {
	local directory digest
	directory=$(mktemp -d "$SWITCH_DIR/.hash.XXXXXX") || return 1
	if cp "$1" "$directory/passwall" &&
		lua /usr/libexec/passwall-guard-digest.lua "$directory" > "$directory/canonical"; then
		digest=$(sha256sum "$directory/canonical" | cut -d' ' -f1)
		rm -rf "$directory"
		printf '%s\n' "$digest"
	else
		rm -rf "$directory"
		return 1
	fi
}

switch_digest() {
	local tmp digest
	tmp=$(mktemp "$SWITCH_DIR/.digest.XXXXXX") || return 1
	switch_export > "$tmp" || { rm -f "$tmp"; return 1; }
	digest=$(switch_digest_file "$tmp") || { rm -f "$tmp"; return 1; }
	rm -f "$tmp"
	printf '%s\n' "$digest"
}

switch_capture() {
	local tmp digest
	tmp=$(mktemp "$SWITCH_DIR/.candidate.XXXXXX") || return 1
	switch_export > "$tmp" && digest=$(switch_digest_file "$tmp") &&
		{ [ -z "$1" ] || [ "$digest" = "$1" ]; } &&
		mv -f "$tmp" "$SWITCH_DIR/candidate" || { rm -f "$tmp"; return 1; }
	switch_write desired "$digest"
}

switch_request() {
	local id
	id=$(cat /proc/sys/kernel/random/uuid) || return 1
	SWITCH_REQUEST="$id $$ $(get_process_start_time $$) $1"
	switch_write request "$SWITCH_REQUEST"
}

switch_request_alive() {
	# Do not let the watcher take a newly queued request away from its caller
	# before that caller acquires the lock. PID start time prevents PID reuse.
	set -- $SWITCH_REQUEST
	local pid="$2" started="$3"
	case "$pid:$started" in ''|*[!0-9:]*|:*|*:) return 1 ;; esac
	[ "$(get_process_start_time "$pid")" = "$started" ]
}

switch_supervisor() {
	/etc/init.d/passwall-guard start >/dev/null 2>&1 || return 1
	local i
	for i in 1 2 3 4 5; do
		busybox pgrep -f '^/bin/sh /usr/libexec/passwall-guard-watch$' >/dev/null && return 0
		sleep 1
	done
	echolog "恢复监控未能启动，取消切换。"
	return 1
}

switch_cancel_stages() {
	local file pid started current group
	# Invalidating first closes the fork-before-registration race in the helper.
	switch_write stage cancelled
	for file in "$SWITCH_DIR"/stages/*; do
		[ -f "$file" ] || continue
		{ read -r pid; read -r started; } < "$file"
		case "$pid" in ''|*[!0-9]*) continue ;; esac
		current=$(get_process_start_time "$pid")
		if [ -n "$started" ] && [ "$current" = "$started" ]; then
			kill -TERM "$pid" 2>/dev/null
			sleep 3
			if [ "$(get_process_start_time "$pid")" = "$started" ]; then
				group=$(awk '{print $5}' "/proc/$pid/stat" 2>/dev/null)
				[ "$group" != "$pid" ] || kill -KILL -- "-$pid" 2>/dev/null
				kill -KILL "$pid" 2>/dev/null
			fi
		fi
		rm -f "$file"
	done
	return 0
}

switch_exec() {
	local stage pid status
	stage=$(cat /proc/sys/kernel/random/uuid) || return 1
	switch_write stage "$stage"
	PASSWALL_TRANSITION_MANAGED=1 /usr/libexec/passwall-guard-stage "$stage" "$SWITCH_REQUEST" "$@" 9>&- 8>&- &
	pid=$!
	while kill -0 "$pid" 2>/dev/null; do
		if ! switch_current; then
			switch_cancel_stages
			wait "$pid" 2>/dev/null
			return 1
		fi
		sleep 1
	done
	wait "$pid"; status=$?
	rm -f "$SWITCH_DIR/stages/$stage"
	return "$status"
}

switch_has_proxy() {
	[ "$(get_cache_var ENABLED_DEFAULT_ACL)" = 1 ] ||
	[ "$(get_cache_var GLOBAL_OPENVPN)" = 1 ] ||
	grep -Eq '^ACL_.*_(redir_port|openvpn|openvpn_global)=' "$TMP_PATH/var" 2>/dev/null
}

switch_probe() {
	local proxy="$1" device="$2" url code host address port
	local urls=$(config_n_get @global[0] switch_guard_probe_url)
	[ -n "$urls" ] || urls="$(config_n_get @global_other[0] url_test_url https://www.google.com/generate_204) https://www.gstatic.com/generate_204"
	for url in $urls; do
		case "$url" in https://*) ;; *) continue ;; esac
		set -- --head --silent --show-error --fail --output /dev/null --write-out '%{http_code}' \
			--connect-timeout 2 --max-time 4 --proto '=https' --noproxy ''
		if [ -n "$proxy" ]; then
			# socks5h resolves the probe hostname through this proxy, with no direct fallback.
			code=$(curl "$@" --proxy "socks5h://$proxy" "$url" 2>/dev/null) || continue
		else
			# A bound VPN device cannot fall back to the WAN. Bootstrap resolution is
			# limited to the configured diagnostic host, just like node resolution.
			host=${url#https://}; host=${host%%/*}
			port=443
			case "$host" in *:*) port=${host##*:}; host=${host%:*} ;; esac
			case "$host:$port" in *[!A-Za-z0-9.:-]*) continue ;; esac
			address=$(get_host_ip ipv4 "$host") || continue
			[ -n "$address" ] || continue
			code=$(run_as_direct_gid curl "$@" --noproxy '*' --interface "$device" \
				--resolve "$host:$port:$address" "$url" 2>/dev/null) || continue
		fi
		case "$code" in 200|204) return 0 ;; esac
	done
	return 1
}

switch_probe_vpn() {
	local dir="$1" device table
	device=$(cat "$dir/dev") && table=$(cat "$dir/table") || return 1
	case "$device" in pswov[0-9]*) ;; *) return 1 ;; esac
	ip -4 route show table "$table" | grep -q "^default dev $device .*metric 10" || return 1
	switch_probe '' "$device"
}

switch_probe_global() {
	local endpoint
	if [ "$(get_cache_var GLOBAL_OPENVPN)" = 1 ]; then
		local dir
		for dir in "$TMP_PATH"/openvpn/nodes/*; do
			[ -f "$dir/global" ] || continue
			switch_probe_vpn "$dir"
			return $?
		done
		return 1
	fi
	endpoint=$(get_cache_var GLOBAL_SOCKS_server)
	[ -n "$endpoint" ] && switch_probe "$endpoint"
}

switch_probe_primary() {
	local primary endpoint
	"$APP_PATH/app.sh" primary_probe || return 1
	if [ "$(get_cache_var GLOBAL_OPENVPN)" = 1 ]; then
		primary=$(get_cache_var FAILOVER_PRIMARY_NODE)
		case "$primary" in ''|*[!A-Za-z0-9_+-]*) return 1 ;; esac
		switch_probe_vpn "$TMP_PATH/openvpn/nodes/$primary"
	else
		endpoint=$(get_cache_var FAILOVER_PRIMARY_SOCKS)
		[ -n "$endpoint" ] && switch_probe "$endpoint"
	fi
}

switch_connected() {
	local key dir
	if [ "$(get_cache_var ENABLED_DEFAULT_ACL)" = 1 ] || [ "$(get_cache_var GLOBAL_OPENVPN)" = 1 ]; then
		switch_probe_global || return 1
	fi
	for key in $(sed -n 's/^\(acl_node_[A-Za-z0-9_]*_socks_port\)=.*/\1/p' "$TMP_PATH/var" 2>/dev/null); do
		switch_probe "127.0.0.1:$(get_cache_var "$key")" || return 1
	done
	for dir in "$TMP_PATH"/openvpn/nodes/*; do
		[ -f "$dir/client.conf" ] && [ ! -f "$dir/global" ] && [ ! -f "$dir/probe_only" ] || continue
		switch_probe_vpn "$dir" || return 1
	done
	return 0
}

switch_wait_ready() {
	local deadline=$(( $(switch_now) + ${1:-30} ))
	while switch_current; do
		if [ -f "$TMP_PATH/start_complete" ] && switch_guard_ready && switch_connected; then
			return 0
		fi
		[ "$(switch_now)" -lt "$deadline" ] || break
		sleep 1
	done
	return 1
}

switch_core_restore() {
	local path
	[ -s "$SWITCH_SAVE/core-update" ] || return 0
	read -r path < "$SWITCH_SAVE/core-update"
	case "$path" in /*) ;; *) return 1 ;; esac
	# Missing backup means the controller died before linking, after restoring,
	# or after committing. Replacement always happens after the link and journal.
	if [ -f "$path.passwall-previous" ]; then
		mv -f "$path.passwall-previous" "$path" || return 1
	else
		[ -x "$path" ] || return 1
	fi
	rm -f "$SWITCH_SAVE/core-update"
	echolog "已恢复更新前的代理核心。"
}

switch_core_commit() {
	local path
	[ -s "$SWITCH_SAVE/core-update" ] || return 0
	read -r path < "$SWITCH_SAVE/core-update"
	rm -f "$path.passwall-previous" "$SWITCH_SAVE/core-update"
}

switch_checkpoint() {
	local tmp digest
	switch_has_proxy || return 0
	umask 077
	mkdir -p "$SWITCH_SAVE" && chmod 700 "$SWITCH_SAVE" || return 1
	if cmp -s "$SWITCH_DIR/candidate" "$SWITCH_SAVE/last-good"; then
		switch_write running "$(switch_read desired)"
		return $?
	fi
	tmp=$(mktemp "$SWITCH_SAVE/.good.XXXXXX") || return 1
	cp "$SWITCH_DIR/candidate" "$tmp" && mv -f "$tmp" "$SWITCH_SAVE/last-good" || return 1
	digest=$(switch_digest_file "$SWITCH_SAVE/last-good") || return 1
	switch_write running "$digest"
}

switch_restore_config() {
	# Subscription workers use POSIX record locks (nixio), not flock locks.
	# Hold that same lock for the digest check and atomic configuration restore.
	PASSWALL_RESTORE_REQUEST="$SWITCH_REQUEST" PASSWALL_UPDATE_LOCK="${LOCK_PATH}/${CONFIG}_sub_rule.lock" \
	lua -e '
		local nixio = require "nixio"
		local file = nixio.open(os.getenv("PASSWALL_UPDATE_LOCK"), "a")
		if not file or not file:lock("tlock") then os.exit(1) end
		if not pcall(function() require("luci.passwall.backup_runtime").recover() end) then os.exit(1) end
		local status = os.execute("/usr/libexec/passwall-guard-restore")
		os.exit(status == 0 and 0 or 1)
	' 9>&-
}

switch_restore_locked() {
	local digest tmp
	[ -s "$SWITCH_SAVE/last-good" ] || return 1
	switch_current || return 1
	digest=$(switch_digest)
	if [ "$digest" != "$(switch_read desired)" ] || ! switch_current; then
		return 1
	fi
	umask 077
	cp "$SWITCH_DIR/candidate" "$SWITCH_SAVE/failed-config"
	tmp=$(mktemp /etc/config/.passwall-recovery.XXXXXX) || return 1
	if cp "$SWITCH_SAVE/last-good" "$tmp" && uci -q revert passwall && mv -f "$tmp" /etc/config/passwall; then
		switch_capture
		return $?
	fi
	rm -f "$tmp"
	return 1
}

switch_finish() {
	local digest
	switch_current || return 1
	digest=$(switch_digest) || return 1
	[ -n "$digest" ] && [ "$digest" = "$(switch_read desired)" ] || return 1
	switch_phase clearing
	switch_guard_end || return 1
	switch_current || return 1
	switch_checkpoint || echolog "无法保存已验证配置，当前代理继续运行。"
	switch_core_commit
	switch_exec 20 "$APP_FILE" finish "$1" || return 1
	switch_settled "${2:-ready}"
}

switch_attempt() {
	switch_current || return 1
	switch_phase starting
	[ "$3" = armed ] || switch_guard_begin || return 1
	rm -f "$SWITCH_DIR/running"
	switch_exec 20 "$APP_FILE" stop || return 1
	switch_current || return 1
	switch_exec 60 "$APP_FILE" start "${4:-primary}" || return 2
	switch_current || return 1
	switch_exec 35 /usr/libexec/passwall-guard-check "$SWITCH_REQUEST" 30 || return 2
	switch_finish "$1" "$2" || return 1
}

switch_attempt_pair() {
	local role="${4:-primary}" alternate status
	switch_attempt "$1" "$2" "$3" "$role" && return 0
	status=$?
	# Only startup or health-check failures warrant trying another exit.
	[ "$status" = 2 ] && switch_current || return 1
	[ "$(config_n_get '@global[0]' enabled 0)" = 1 ] &&
		global_backup_node "$(config_n_get '@global[0]' node)" >/dev/null || return 1
	[ "$(switch_digest)" = "$(switch_read desired)" ] || return 1
	alternate=backup
	[ "$role" != backup ] || alternate=primary
	echolog "主备切换：当前出口未通过验证，尝试另一节点。"
	switch_attempt "$1" "$2" '' "$alternate"
}

switch_failed() {
	switch_current || return 1
	local attempts=$(switch_read attempts)
	case "$attempts" in ''|*[!0-9]*) attempts=0 ;; esac
	attempts=$((attempts + 1))
	switch_write attempts "$attempts"
	local delay=$((attempts * 5))
	[ "$delay" -le 30 ] || delay=30
	switch_write retry_at "$(( $(switch_now) + delay ))"
	switch_phase failed
	switch_result blocked
	echolog "切换未验证通过，保持保护；恢复监控将在 ${delay} 秒后重试。"
	return 1
}

switch_run() {
	local action="$1" role="${2:-primary}" expected="$3" old_ok=0
	switch_current || return 0
	switch_capture "$expected" || return 1
	if ! switch_guard_needed && [ "$(config_n_get @global[0] enabled 0)" != 1 ] &&
		[ "$(config_n_get @global[0] acl_enable 0)" != 1 ]; then
		switch_core_restore || return 1
		switch_exec 20 "$APP_FILE" stop || return 1
		switch_exec 60 "$APP_FILE" start || return 1
		switch_current || return 1
		switch_guard_end || return 1
		switch_exec 20 "$APP_FILE" finish "$action" || return 1
		switch_settled ready
		return $?
	fi
	switch_supervisor || return 1
	if [ -s "$SWITCH_DIR/running" ] && [ -s "$SWITCH_SAVE/last-good" ] &&
		[ "$(switch_read running)" = "$(switch_digest_file "$SWITCH_SAVE/last-good")" ] &&
		switch_guard_ready && switch_exec 12 /usr/libexec/passwall-guard-check "$SWITCH_REQUEST" 1; then
		old_ok=1
	fi
	switch_phase preparing
	switch_result switching
	if ! switch_guard_begin; then
		if [ "$old_ok" = 1 ] && switch_restore_config && switch_guard_end; then
			switch_settled cancelled
			echolog "保护未能完整安装，已取消切换并恢复原配置；旧代理继续运行。"
			return 1
		fi
		switch_failed
		return 1
	fi
	if switch_attempt_pair "$action" '' armed "$role"; then return 0; fi
	switch_current || return 1
	switch_core_restore || { switch_failed; return 1; }
	# A runtime failover has already tried both exits of the verified config.
	# Restoring identical settings would repeat the outage and rewrite flash.
	if [ -n "$expected" ] && cmp -s "$SWITCH_DIR/candidate" "$SWITCH_SAVE/last-good"; then
		switch_failed
		return 1
	fi
	if switch_restore_config; then
		echolog "新配置未验证通过，正在回退最近一次验证成功的配置。"
		if switch_attempt_pair '' rolled_back; then return 1; fi
	fi
	switch_failed
}

switch_stop() {
	switch_phase stopping
	switch_exec 20 "$APP_FILE" stop || return 1
	switch_current || return 1
	switch_core_restore || return 1
	switch_guard_end || return 1
	rm -f "$SWITCH_DIR/running"
	switch_settled stopped
}

switch_failover_due() {
	local next
	[ -f "$TMP_PATH/failover_next" ] && read -r next < "$TMP_PATH/failover_next" || return 1
	[ "$(switch_now)" -ge "$next" ]
}

switch_failover_tick() {
	local failures=0 recoveries=0 role=backup digest
	switch_failover_due || return 0
	echo $(( $(switch_now) + 30 )) > "$TMP_PATH/failover_next"
	read -r failures recoveries < "$TMP_PATH/failover_counts" 2>/dev/null || { failures=0; recoveries=0; }
	if switch_exec 20 /usr/libexec/passwall-guard-check active; then failures=0; else failures=$((failures + 1)); fi
	if [ "$(get_cache_var FAILOVER_ROLE)" = backup ]; then
		role=primary
		if switch_current && switch_exec 20 /usr/libexec/passwall-guard-check primary; then
			recoveries=$((recoveries + 1))
		else
			recoveries=0
		fi
	fi
	switch_current || return 1
	echo "$failures $recoveries" > "$TMP_PATH/failover_counts"
	[ "$failures" -ge 3 ] || [ "$recoveries" -ge 3 ] || return 0
	digest=$(switch_read running)
	[ -n "$digest" ] && wait_updates && switch_current || return 0
	if [ "$role" = backup ]; then
		echolog "主节点连续三次检测失败，尝试切换到备用节点。"
	else
		echolog "主节点恢复或备用节点连续检测失败，尝试回切主节点。"
	fi
	switch_run '' "$role" "$digest"
}

switch_recover() {
	local phase=$(switch_read phase) now=$(switch_now) deadline=$(switch_read retry_at)
	case "$SWITCH_REQUEST" in *' stop') switch_stop; return ;; esac
	case "$phase" in ''|idle)
		if [ "$(switch_read handled)" = "$SWITCH_REQUEST" ]; then
			case "$(switch_read result)" in ready|rolled_back|cancelled) ;; *) return 0 ;; esac
			switch_has_proxy || return 0
			[ "$(switch_digest)" = "$(switch_read running)" ] || return 0
			switch_guard_ready && return 0
			echolog "检测到代理进程或监听端口失效，启用保护并恢复服务。"
			switch_run '' "$(get_cache_var FAILOVER_ROLE)"
			return
		fi
		switch_run
		return
		;;
	esac
	case "$deadline" in ''|*[!0-9]*) deadline=0 ;; esac
	[ "$now" -ge "$deadline" ] || return 0
	if [ "$phase" != updating ] && [ "$(switch_digest)" = "$(switch_read desired)" ] &&
		switch_exec 12 /usr/libexec/passwall-guard-check "$SWITCH_REQUEST" 5 && switch_finish; then
		return 0
	fi
	switch_core_restore || { switch_failed; return 1; }
	if [ "$phase" = starting ] || [ "$phase" = updating ]; then
		switch_restore_config || true
	fi
	switch_run
}
