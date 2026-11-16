(function(root) {
	'use strict';
	if (root.PasswallRequest) return;
	var api = {token: ''};
	function sameOrigin(url) {
		var target = new URL(url, root.location.href);
		if (target.origin !== root.location.origin) throw new Error('Invalid action origin');
		return target.href;
	}
	function body(data) {
		var result = new URLSearchParams(data || {});
		result.set('token', api.token);
		return result;
	}
	api.post = function(url, data, callback, timeout) {
		var xhr = new XMLHttpRequest(), done = false;
		function finish() {
			if (done) return;
			done = true;
			var value = null;
			try { value = JSON.parse(xhr.responseText); } catch (_) {}
			if (callback) callback(xhr, value);
		}
		xhr.open('POST', sameOrigin(url), true);
		xhr.timeout = (timeout || 30) * 1000;
		xhr.setRequestHeader('Content-Type', 'application/x-www-form-urlencoded');
		xhr.onload = xhr.onerror = xhr.ontimeout = finish;
		xhr.send(body(data).toString());
		return xhr;
	};
	api.fetch = function(url, data) {
		return root.fetch(sameOrigin(url), {method: 'POST', credentials: 'same-origin', body: body(data)});
	};
	api.navigate = function(url, data) {
		var target = sameOrigin(url);
		var form = document.createElement('form');
		form.method = 'POST'; form.action = target; form.style.display = 'none';
		body(data).forEach(function(value, key) {
			var input = document.createElement('input');
			input.type = 'hidden'; input.name = key; input.value = value;
			form.appendChild(input);
		});
		document.body.appendChild(form); form.submit(); form.remove();
	};
	root.PasswallRequest = api;
})(window);
