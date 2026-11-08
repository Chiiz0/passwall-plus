'use strict';
'require baseclass';

function el(tag, attrs, children) {
	var node = document.createElement(tag);
	Object.keys(attrs || {}).forEach(function(key) {
		if (key === 'class') node.className = attrs[key];
		else node.setAttribute(key, attrs[key]);
	});
	(children || []).forEach(function(child) { node.appendChild(typeof child === 'string' ? document.createTextNode(child) : child); });
	return node;
}
function clear(node, children) { if (node) node.replaceChildren.apply(node, children); }
function pill(text, kind) { return el('span', {class:'pw-pill ' + (kind || '')}, [text]); }
function link(base, path, text) { return el('a', {href:base + '/' + path}, [text]); }
function bytes(value) {
	var unit = ['B', 'KiB', 'MiB', 'GiB', 'TiB'], i = 0;
	while (value >= 1024 && i < unit.length - 1) { value /= 1024; i++; }
	return value.toFixed(i ? 1 : 0) + ' ' + unit[i];
}
function vpnLabel(state) {
	return ({unused:_('Not started'), tunnel_up:_('Tunnel route established'), connecting:_('Connecting / reconnecting'), not_running:_('Tunnel process absent')})[state] || _('Unknown');
}
function ruleLabel(state) {
	return ({acl_off:_('Device policies are off'), disabled:_('Disabled'), guard_pending:_('Protection / recovery in progress'), loaded:_('Runtime rule loaded'), not_applied:_('No applied runtime record')})[state] || _('Unknown');
}
function guardLabel(guard) {
	if (guard.pending) return _('Protection / recovery in progress');
	return ({ready:_('Last switch verified'), rolled_back:_('Previous verified configuration restored'), cancelled:_('Switch cancelled; previous proxy retained'), blocked:_('Recovery pending; inspect logs'), switching:_('Switch in progress'), stopped:_('Stopped; normal network restored')})[guard.result] || _('No switch result yet');
}
function nodeName(node) { return node && node.name ? node.name : _('No exit selected'); }
function metric(label, value, note) {
	return el('div', {class:'pw-metric'}, [el('span', {class:'pw-muted'}, [label]), el('strong', {class:'pw-value'}, [String(value)]), el('small', {}, [note])]);
}
function vpnCard(base, vpn, token) {
	var assign = el('form', {method:'post', action:base + '/plus_create'}, [
		el('input', {type:'hidden', name:'token', value:token}),
		el('input', {type:'hidden', name:'kind', value:'device'}),
		el('input', {type:'hidden', name:'node', value:vpn.id}),
		el('button', {type:'submit', class:'cbi-button'}, [_('Assign to a new device')])
	]);
	if (!token) assign = link(base, 'acl', _('Assign devices'));
	var facts = [];
	function fact(label, value) { facts.push(el('dt', {}, [label]), el('dd', {}, [value])); }
	fact(_('Assigned to'), (vpn.global ? _('Global exit') + ' · ' : '') + vpn.assignments + ' ' + _('enabled device rules'));
	fact(_('Tunnel DNS'), vpn.dns);
	fact(_('Pre-proxy node'), vpn.preproxy_id ? nodeName(vpn.preproxy) : _('Direct Connection'));
	fact(_('Tunnel interface'), vpn.device || '—');
	fact(_('Received / sent'), bytes(vpn.rx_bytes) + ' / ' + bytes(vpn.tx_bytes));
	return el('article', {class:'pw-vpn-card'}, [
		el('div', {class:'pw-vpn-title'}, [el('h3', {}, [vpn.name]), pill(vpnLabel(vpn.status), vpn.status === 'tunnel_up' ? '' : (vpn.status === 'unused' ? 'neutral' : 'warn'))]),
		el('dl', {class:'pw-facts'}, facts),
		el('div', {class:'pw-actions'}, [link(base, 'node_config/' + encodeURIComponent(vpn.id), _('Edit profile')), assign, link(base, 'log', _('Runtime Logs'))])
	]);
}
function showProtection() {
	var tab = document.querySelector('.cbi-tabmenu [data-tab="Proxy"] a');
	if (!tab) return false;
	tab.click();
	var field = document.querySelector('[id^="cbid.passwall."][id$=".switch_guard"]');
	if (field) field.scrollIntoView({block:'center'});
	return true;
}
function renderProtection(root, data, base) {
	var settings = link(base, 'settings#plus-protection', _('Protection settings'));
	if (root.dataset.mode === 'global') {
		settings = el('button', {type:'button', class:'cbi-button'}, [_('Protection settings')]);
		settings.addEventListener('click', showProtection);
	}
	var g = data.guard, message;
	if (g.pending) message = _('The switch controller is protecting or recovering the network. Check the result and logs before treating an exit as usable.');
	else if (!g.enabled) message = _('Switch protection is disabled. Enable it in Global egress to pause traffic during node changes.');
	else message = _('Switch protection verifies the proxy or VPN before resuming traffic. The last result is not a continuous Internet health test.');
	var ipv6 = data.global.reject_ipv6 ? _('IPv6 rejection configured for:') + ' ' + data.global.ipv6_zones.join(', ') : _('IPv6 rejection is disabled');
	clear(root.querySelector('#pw-protection'), [el('div', {class:'pw-notice' + (g.pending || !g.enabled ? ' pw-warning' : '')}, [
		el('strong', {}, [guardLabel(g)]), el('p', {}, [message]),
		el('p', {class:'pw-muted'}, [_('Switch protection preserves DHCP address assignment. While DNS is paused, open LuCI using the router LAN IP.')]),
		el('p', {class:'pw-muted'}, [ipv6]),
		el('div', {class:'pw-actions'}, [settings, link(base, 'log', _('Runtime Logs'))])])]);
}
function renderDevices(root, data, base) {
	var query = (root.querySelector('#pw-device-search').value || '').toLowerCase();
	var devices = data.devices.filter(function(d) { return [d.name, d.ip, d.mac, d.hostname, nodeName(d.node), d.sources.join(' ')].join(' ').toLowerCase().includes(query); });
	var rows = devices.map(function(d) {
		var source = d.bound ? d.ip + ' · ' + d.mac : (d.sources.join(', ') || _('All sources'));
		var target = d.mode === 'direct' ? _('Direct Connection') : nodeName(d.node);
		var route = d.mode === 'global' ? _('Follow global configuration') : (d.node.type === 'OpenVPN' && d.mode !== 'direct' ? _('OpenVPN full IPv4 forwarding') : _('Device routing policy'));
		var binding = d.bound ? _('IP/MAC binding') : _('Source matching');
		var lease = d.bound ? (d.lease ? (d.lease_matches ? _('Matching DHCP lease') : _('DHCP address differs; renew the lease')) : _('No current DHCP lease')) : (d.interface || _('All interfaces'));
		return el('div', {class:'pw-device'}, [
			el('div', {}, [el('strong', {}, [String(d.order).padStart(2, '0') + ' · ' + d.name]), el('small', {}, [source])]),
			el('div', {}, [pill(binding, d.bound ? '' : 'neutral'), el('small', {}, [lease])]),
			el('div', {class:'pw-device-route'}, [el('strong', {}, ['→ ' + target]), el('small', {}, [route]), pill(ruleLabel(d.state), d.state === 'loaded' ? '' : 'warn'),
				el('small', {}, [d.vpn_state ? vpnLabel(d.vpn_state) : _('Connectivity not measured here')])]),
			link(base, 'acl_config/' + encodeURIComponent(d.id), _('Configure'))
		]);
	});
	clear(root.querySelector('#pw-devices'), rows.length ? rows : [el('div', {class:'pw-empty'}, [query ? _('No matching devices.') : _('No device policies yet. Add a device, bind its IP/MAC, then choose an exit.')])]);
}
function renderRuntime(root, data, base) {
	var runtime = data.global.firewall_error ? _('Firewall setup reported an error') : (data.global.start_complete ? _('Last startup completed') : _('No completed startup record'));
	clear(root.querySelector('#pw-runtime'), [el('div', {class:'pw-panel'}, [
		el('div', {class:'pw-section-head'}, [el('h3', {}, [_('Global runtime')]), link(base, root.dataset.mode === 'global' ? 'overview' : 'settings', (root.dataset.mode === 'global' ? _('Plus Overview') : _('Global egress')) + ' →')]),
		el('div', {class:'pw-actions'}, [pill(runtime, data.global.firewall_error ? 'warn' : 'neutral'), pill(data.global.firewall_ready ? _('Firewall readiness recorded') : _('No firewall readiness record'), 'neutral')]),
		el('p', {class:'pw-muted'}, [_('Runtime exit record') + ': ' + nodeName(data.global.runtime_node) + ' · ' + _('Saved selection and runtime records can differ until changes are applied.')])
	])]);
}
function renderDashboard(root, data, base) {
	var mode = root.dataset.mode;
	renderProtection(root, data, base);
	if (mode === 'global') {
		renderRuntime(root, data, base);
		clear(root.querySelector('#pw-vpns'), data.vpns.filter(function(v) { return v.global || v.runtime_global; }).map(function(v) { return vpnCard(base, v); }));
		return;
	}
	clear(root.querySelector('#pw-vpns'), data.vpns.length ? data.vpns.map(function(v) { return vpnCard(base, v, root.dataset.token); }) : [el('div', {class:'pw-empty'}, [data.openvpn_installed ? _('No OpenVPN profiles yet. Import your first profile to get started.') : _('OpenVPN is not installed. Install the OpenVPN component first.')])]);
	if (mode === 'openvpn') {
		root.querySelector('#pw-add-vpn').disabled = !data.openvpn_installed;
		return;
	}
	clear(root.querySelector('#pw-summary'), [
		metric(_('Global egress'), data.global.enabled ? nodeName(data.global.node) : _('Global proxy off'), data.global.enabled ? _('Saved selection; runtime state shown below') : _('Device policies can run independently')),
		metric(_('Device policies'), data.counts.enabled + ' / ' + data.counts.rules, data.global.acl_enabled ? _('Enabled rules / all rules') : _('Device policy master switch is off')),
		metric(_('OpenVPN tunnels'), data.counts.tunnels + ' / ' + data.vpns.length, _('Established routes / configured profiles')),
		metric(_('Device identity'), data.counts.bindings, _('Policies with IP/MAC binding'))
	]);
	renderRuntime(root, data, base);
	renderDevices(root, data, base);
	clear(root.querySelector('#pw-leases'), [data.leases.length ? el('div', {class:'pw-leases'}, data.leases.map(function(lease) {
		return el('div', {class:'pw-lease'}, [el('strong', {}, [lease.name || _('Unnamed device')]), el('span', {}, [lease.ip]), el('span', {}, [lease.mac])]);
	})) : el('div', {class:'pw-empty'}, [_('No current DHCP leases. Devices with static addresses can be entered manually.')])]);
}

return baseclass.extend({
	dashboard: function(root) {
		var base = root.dataset.base.replace(/\/$/, ''), last = null, busy = false, timer, focused = false;
		function focusProtection() { if (!focused && root.dataset.mode === 'global' && location.hash === '#plus-protection') focused = showProtection(); }
		document.addEventListener('luci-loaded', focusProtection, {once:true});
		var refresh = root.querySelector('#pw-refresh'), error = root.querySelector('#pw-error');
		async function update() {
			if (busy) return;
			clearTimeout(timer);
			if (document.hidden) { timer = setTimeout(update, 10000); return; }
			busy = true; refresh.disabled = true;
			var controller = new AbortController(), timeout = setTimeout(function() { controller.abort(); }, 8000);
			try {
				var response = await fetch(base + '/plus_status', {credentials:'same-origin', cache:'no-store', signal:controller.signal});
				if (!response.ok) throw new Error('status');
				var data = await response.json();
				['devices','vpns','leases','nodes'].forEach(function(key) { if (!Array.isArray(data[key])) data[key] = []; });
				last = data;
				renderDashboard(root, data, base);
				focusProtection();
				root.dataset.stale = 'false'; error.hidden = true;
				root.querySelector('#pw-updated').textContent = _('Updated') + ' ' + new Date().toLocaleTimeString() + ' · ' + _('Refreshes every 10 seconds');
			} catch (e) {
				root.dataset.stale = 'true'; error.hidden = false;
				error.textContent = _('Status refresh failed. Displayed values may be stale; check your connection or sign in again.');
			} finally { clearTimeout(timeout); busy = false; refresh.disabled = false; timer = setTimeout(update, 10000); }
		}
		refresh.addEventListener('click', update);
		var search = root.querySelector('#pw-device-search');
		if (search) search.addEventListener('input', function() { if (last) renderDevices(root, last, base); });
		document.addEventListener('visibilitychange', function() { if (!document.hidden) update(); });
		window.addEventListener('pagehide', function() { clearTimeout(timer); });
		update();
	}
});
