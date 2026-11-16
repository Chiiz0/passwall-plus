/* Verify transport, CSRF, encoding and callbacks used by legacy LuCI pages. */
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
let sent, submitted, fetched;
class XHR {
	open(method, url) { this.method = method; this.url = url; }
	setRequestHeader(key, value) { this[key] = value; }
	send(body) { this.body = new URLSearchParams(body); sent = this; }
}
const document = {
	body: {appendChild() {}},
	createElement(tag) {
		return {tag, style: {}, children: [], appendChild(child) { this.children.push(child); },
			submit() { submitted = this; }, remove() { this.removed = true; }};
	}
};
const window = {
	location: {href: 'http://router.test/cgi-bin/luci/admin/services/passwall/settings', origin: 'http://router.test'},
	fetch(url, options) { fetched = {url, options}; return Promise.resolve({ok: true}); }
};
const context = vm.createContext({window, document, URL, URLSearchParams, XMLHttpRequest: XHR});
const source = fs.readFileSync(process.argv[2] || 'luci-app-passwall/htdocs/luci-static/resources/view/passwall/request.js', 'utf8');
vm.runInContext(source, context);
const api = window.PasswallRequest;
api.token = 'test-token';
let callbacks = 0;
api.post('/action', {token: 'untrusted', group: "中文,'& $(literal)"}, (xhr, value) => {
	callbacks++;
	assert.equal(value.status, 'ok');
});
assert.equal(sent.method, 'POST');
assert.equal(sent.body.get('token'), 'test-token');
assert.equal(sent.body.get('group'), "中文,'& $(literal)");
assert.equal(sent['Content-Type'], 'application/x-www-form-urlencoded');
sent.responseText = '{"status":"ok"}'; sent.onload(); sent.onerror(); sent.ontimeout();
assert.equal(callbacks, 1);
api.fetch('/action', new URLSearchParams({urls: '["https://test/?a=1,2"]'}));
assert.equal(fetched.options.method, 'POST');
assert.equal(fetched.options.credentials, 'same-origin');
assert.equal(fetched.options.body.get('token'), 'test-token');
assert.equal(fetched.options.body.get('urls'), '["https://test/?a=1,2"]');
api.navigate('/action', {ids: 'node1,node2'});
assert.equal(submitted.method, 'POST');
assert.equal(submitted.children.find(field => field.name === 'token').value, 'test-token');
assert.equal(submitted.children.find(field => field.name === 'ids').value, 'node1,node2');
assert.equal(submitted.removed, true);
for (const method of ['post', 'fetch', 'navigate']) {
	assert.throws(() => api[method]('https://outside.test/action'), /Invalid action origin/);
}
vm.runInContext(source, context);
assert.equal(window.PasswallRequest, api);
assert.equal(api.token, 'test-token');
console.log('PASS LuCI POST transport, CSRF token, Unicode encoding, callback completion and same-origin restriction');
