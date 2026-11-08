'use strict';
'require baseclass';
'require dom';

function ready(fn) { if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', fn, {once:true}); else fn(); }
function el(tag, className, text) { var n = document.createElement(tag); if (className) n.className = className; if (text) n.textContent = text; return n; }
function inspectProfile(text) {
	var value = text.replace(/^\uFEFF/, '').replace(/\r\n/g, '\n').trim();
	var result = {value:value, remotes:[], protocols:[], external:[], inline:[], auth:false, errors:[]};
	if (!value) result.errors.push(_('OpenVPN client profile is required.'));
	if (new TextEncoder().encode(value).length > 131072) result.errors.push(_('OpenVPN client profile must not exceed 128 KiB.'));
	if (value.includes('\0')) result.errors.push(_('OpenVPN client profile contains invalid data.'));
	var inline = null, ipv4Remote = false;
	value.split('\n').forEach(function(line) {
		line = line.trim();
		var lower = line.toLowerCase();
		if (inline) { if (lower === '</' + inline + '>') inline = null; return; }
		var tag = lower.match(/^<([\w-]+)>$/);
		if (tag && tag[1] !== 'connection') {
			inline = tag[1]; result.inline.push(inline);
			if (inline === 'auth-user-pass') result.auth = true;
			return;
		}
		if (!line || /^[#;<]/.test(line)) return;
		var args = line.replace(/^--/, '').split(/\s+/), key = args[0].toLowerCase();
		if (key === 'remote' && args[1]) {
			result.remotes.push(args[1] + (args[2] ? ':' + args[2] : ''));
			if (!args[1].includes(':') && !args[1].startsWith('[')) ipv4Remote = true;
			if (args[3]) result.protocols.push(args[3].toLowerCase());
		}
		if (key === 'proto' && args[1]) result.protocols.push(args[1].toLowerCase());
		if (key === 'auth-user-pass') result.auth = true;
		if (/^(ca|cert|key|pkcs12|tls-auth|tls-crypt|tls-crypt-v2|extra-certs|crl-verify)$/.test(key) && args[1] && args[1] !== '[inline]') result.external.push(key);
	});
	if (value && !result.remotes.length) result.errors.push(_('OpenVPN client profile must contain a remote directive.'));
	if (result.remotes.length && !ipv4Remote) result.errors.push(_('This firmware requires an IPv4 address or hostname in a remote directive.'));
	return result;
}
function field(root, option) { return document.getElementById('cbid.' + root.dataset.config + '.' + root.dataset.section + '.' + option); }
function value(root, option) {
	var f = field(root, option), widget = f && dom.findClassInstance(f);
	return widget ? String(widget.getValue() || '') : (f ? (f.type === 'checkbox' ? (f.checked ? '1' : '0') : f.value) : '');
}
function setField(root, option, text) {
	var f = field(root, option); if (!f) return;
	var widget = dom.findClassInstance(f);
	if (widget) widget.setValue(text);
	else if (f.type === 'checkbox') f.checked = text === '1';
	else f.value = text;
	f.dispatchEvent(new CustomEvent('widget-update', {bubbles:true}));
	f.dispatchEvent(new CustomEvent('widget-change', {bubbles:true}));
	f.dispatchEvent(new Event('input', {bubbles:true}));
	f.dispatchEvent(new Event('change', {bubbles:true}));
}
function profileSummary(root, report, importMessage) {
	var output = root.querySelector('.pw-profile-summary'); output.replaceChildren();
	var errors = report.errors.slice(), warnings = [];
	var user = value(root, 'openvpn_username'), password = value(root, 'openvpn_password');
	if ((!!user) !== (!!password)) errors.push(_('OpenVPN username and password must be configured together.'));
	if (report.auth && !user && !password) warnings.push(_('This profile requests a username and password. Enter them in the authentication fields below; profile-embedded credentials are not used.'));
	if (report.external.length) warnings.push(_('External certificate/key files are referenced. Use a profile with inline certificates, or ensure the referenced files exist on the router.') + ' (' + Array.from(new Set(report.external)).join(', ') + ')');
	if (value(root, 'openvpn_preproxy_node')) warnings.push(_('Pre-proxy uses TCP. Confirm that the VPN server supports TCP on this port; a UDP-only endpoint will not work.'));
	if (importMessage) output.appendChild(el('p', 'pw-muted', importMessage));
	if (report.remotes.length) {
		var facts = el('div', 'pw-profile-facts');
		facts.appendChild(el('span', '', _('Server endpoints') + ': ' + report.remotes.join(', ')));
		facts.appendChild(el('span', '', _('Profile transport') + ': ' + (report.protocols.length ? Array.from(new Set(report.protocols)).join(' / ').toUpperCase() : 'UDP')));
		facts.appendChild(el('span', '', _('Inline certificate blocks') + ': ' + report.inline.filter(function(t) { return t !== 'auth-user-pass'; }).length));
		output.appendChild(facts);
	}
	errors.concat(warnings).forEach(function(message) { output.appendChild(el('p', 'pw-notice pw-warning', message)); });
	if (!errors.length) output.appendChild(el('p', 'pw-muted', _('Profile structure detected. Authentication and connectivity are verified only when the tunnel starts.')));
}

return baseclass.extend({
	inspectProfile: inspectProfile,
	profiles: function() { ready(function() {
		document.querySelectorAll('.pw-profile-editor').forEach(function(root) {
			var textarea = document.getElementById(root.dataset.field), input = root.querySelector('.pw-profile-file');
			if (!textarea || root.dataset.bound) return; root.dataset.bound = 'true';
			var message = '';
			function update() { profileSummary(root, inspectProfile(textarea.value), message); }
			textarea.addEventListener('input', update);
			// CBI replaces widget placeholders after this template has rendered.
			var form = root.closest('form');
			if (form) ['input', 'change', 'widget-change'].forEach(function(event) { form.addEventListener(event, update); });
			document.addEventListener('luci-loaded', update, {once:true});
			if (!textarea.value.trim()) root.querySelector('details').open = true;
			['openvpn_username','openvpn_password','openvpn_preproxy_node'].forEach(function(name) {
				var f = field(root, name); if (f) { f.addEventListener('input', update); f.addEventListener('change', update); }
			});
			input.addEventListener('change', async function() {
				var file = input.files[0]; if (!file) return;
				try {
					if (file.size > 131072) throw new Error(_('OpenVPN client profile must not exceed 128 KiB.'));
					var report = inspectProfile(await file.text());
					if (report.errors.length) throw new Error(report.errors.join(' '));
					textarea.value = report.value;
					textarea.dispatchEvent(new Event('change', {bubbles:true}));
					message = _('Imported into the form; not applied yet.') + ' ' + file.name;
					update();
				} catch (e) {
					message = _('Import failed; the previous profile was kept.') + ' ' + e.message;
					update();
				} finally { input.value = ''; }
			});
			update();
		});
	}); },
	device: function(root) { ready(async function() {
		var select = root.querySelector('#pw-lease-select'), button = root.querySelector('#pw-use-lease'), status = root.querySelector('#pw-lease-message');
		var data = {leases:[], nodes:[], global:{}}, loaded = false;
		function preview() {
			var target = root.querySelector('#pw-policy-preview'); target.replaceChildren();
			var bound = value(root, 'bind_enable') === '1', enabled = value(root, 'enabled') === '1';
			var mode = value(root, 'mode'), global = value(root, 'use_global_config') === '1';
			var id = global ? ((data.global.node || {}).id || '') : value(root, 'node');
			var node = data.nodes.find(function(n) { return n && n.id === id; });
			var name = mode !== '1' ? _('Direct Connection') : (node ? node.name : (id || _('No exit selected')));
			var identity = bound ? [value(root, 'bind_ip'), value(root, 'bind_mac')].filter(Boolean).join(' · ') : _('Source matching');
			target.appendChild(el('strong', '', _('Policy preview') + ' · ' + (value(root, 'remarks') || _('Unnamed device'))));
			target.appendChild(el('p', '', (identity || _('Choose a device identity')) + ' → ' + name));
			target.appendChild(el('p', '', enabled ? _('This rule will be enabled after Save & Apply.') : _('This rule is disabled. Enable it when the configuration is ready.')));
			if (loaded && !data.global.acl_enabled) target.appendChild(el('p', 'pw-warning', _('The device policy master switch is off. Enabled rules with binding turn it on when saved; otherwise enable it on the device policies page.')));
			if (global && mode === '1') target.appendChild(el('p', '', _('Follow global configuration')));
			if (node && node.type === 'OpenVPN' && mode === '1') {
				target.appendChild(el('p', '', _('OpenVPN forwards all IPv4 traffic and port 53 DNS through the tunnel.')));
				if (!global && !bound) target.appendChild(el('p', 'pw-warning', _('OpenVPN device forwarding requires a valid enabled IP/MAC binding.')));
				if (!global) target.appendChild(el('p', 'pw-muted', value(root, 'openvpn_allow_lan') === '1' ? _('Local LAN access is allowed.') : _('Local LAN access is isolated except DHCP.')));
			}
		}
		// CBI node pickers update hidden values; listen on the form as well as inputs.
		var form = root.closest('form');
		if (form) { form.addEventListener('change', preview); form.addEventListener('input', preview); form.addEventListener('widget-change', preview); }
		document.addEventListener('luci-loaded', preview, {once:true});
		button.addEventListener('click', function() {
			var lease = data.leases[Number(select.value)]; if (!lease) return;
			setField(root, 'bind_enable', '1');
			setField(root, 'bind_mac', lease.mac); setField(root, 'bind_ip', lease.ip);
			setField(root, 'bind_hostname', lease.name || '');
			if (!value(root, 'remarks') || value(root, 'remarks') === root.dataset.section) setField(root, 'remarks', lease.name || lease.ip);
			status.textContent = _('Device details filled. Review the exit and enable the rule before applying.'); preview();
		});
		select.addEventListener('change', function() { button.disabled = select.value === ''; });
		preview();
		var controller = new AbortController(), timeout = setTimeout(function() { controller.abort(); }, 8000);
		try {
			var response = await fetch(root.dataset.base.replace(/\/$/, '') + '/plus_status', {credentials:'same-origin', cache:'no-store', signal:controller.signal});
			if (!response.ok) throw new Error('status');
			data = await response.json();
			if (!Array.isArray(data.leases)) data.leases = []; if (!Array.isArray(data.nodes)) data.nodes = [];
			loaded = true; select.replaceChildren(new Option(_('Choose a device…'), ''));
			data.leases.forEach(function(lease, i) { select.add(new Option((lease.name || _('Unnamed device')) + ' · ' + lease.ip + ' · ' + lease.mac, String(i))); });
			select.disabled = !data.leases.length;
			status.textContent = data.leases.length ? _('Leases do not prove a device is online. You can also enter a static address below.') : _('No current DHCP leases. Enter the device MAC and IPv4 address below.');
		} catch (e) {
			select.replaceChildren(new Option(_('Device discovery unavailable'), ''));
			status.textContent = _('Could not load leases. Enter the device details manually or reload this page.');
		} finally { clearTimeout(timeout); preview(); }
	}); }
});
