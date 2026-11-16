#!/usr/bin/env python3
"""Exercise installed LuCI action security and imports in a disposable guest."""
import argparse
import base64
import json
import re
import shlex
import subprocess
import urllib.parse
from html.parser import HTMLParser

parser = argparse.ArgumentParser()
parser.add_argument('--ssh-port', type=int, default=2322)
args = parser.parse_args()
SSH = ['ssh', '-p', str(args.ssh_port), '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=3',
       '-o', 'StrictHostKeyChecking=no', '-o', 'UserKnownHostsFile=/dev/null', '-o', 'LogLevel=ERROR', 'root@127.0.0.1']

def shell(code):
    return subprocess.check_output(SSH + ['/bin/sh'], input=code.encode()).decode()

def ubus(method, data):
    return json.loads(shell('ubus call session ' + method + ' ' + shlex.quote(json.dumps(data))) or '{}')

sessions = []
TOKEN = 'qemu-http-security-test'

def login():
    sid = ubus('login', {'username': 'root', 'password': ''})['ubus_rpc_session']
    sessions.append(sid)
    ubus('set', {'ubus_rpc_session': sid, 'values': {'token': TOKEN}})
    return sid

def request(sid, path, data=None):
    cmd = ['curl', '--max-time', '45', '-sS', '-b', 'sysauth_http=' + sid,
           '-D', '/tmp/pw-security-headers', '-o', '/tmp/pw-security-body']
    if data is not None:
        cmd += ['--data', urllib.parse.urlencode(data)]
    config = 'url = ' + json.dumps('http://127.0.0.1/cgi-bin/luci/admin/services/passwall/' + path) + '\n'
    result = shell("printf '%s' " + shlex.quote(config) + ' | ' + shlex.join(cmd + ['--config', '-']) +
                   '\nhead -n 1 /tmp/pw-security-headers\nbase64 /tmp/pw-security-body')
    status, body = result.split('\n', 1)
    return int(status.split()[1]), base64.b64decode(body)

def post(sid, path, **data):
    return request(sid, path, dict(token=TOKEN, **data))

def config_hash():
    return shell('sha256sum /etc/config/passwall /etc/config/passwall_server')

class Scripts(HTMLParser):
    def __init__(self):
        super().__init__(); self.scripts = []; self.current = None
    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if tag == 'script' and attrs.get('type', '') in ('', 'text/javascript'):
            self.current = ''
    def handle_data(self, data):
        if self.current is not None: self.current += data
    def handle_endtag(self, tag):
        if tag == 'script' and self.current is not None:
            self.scripts.append(self.current); self.current = None

original = shell('base64 /etc/config/passwall')
sid = login()
try:
    for page in ('settings', 'node_list', 'node_subscribe', 'rule', 'app_update', 'log', 'show', 'hide', 'server'):
        status, body = request(sid, page)
        assert status == 200, (page, status, body[-2000:])
        scripts = Scripts(); scripts.feed(body.decode())
        for script in scripts.scripts:
            parsed = subprocess.run(['node', '--check'], input=script, text=True, capture_output=True)
            assert parsed.returncode == 0, (page, parsed.stderr)
    print('PASS rendered LuCI pages and embedded JavaScript syntax', flush=True)

    routes = ['plus_create', 'update_config', 'server_update_config', 'add_node', 'copy_node', 'set_node',
              'clear_all_nodes', 'delete_select_nodes', 'reassign_group', 'save_node_list_opt', 'flush_set',
              'add_shunt_rule', 'delete_select_shunt_rules', 'socks_autoswitch_add_node', 'socks_autoswitch_remove_node',
              'link_add_node', 'clear_log', 'server_clear_log', 'update_rules', 'rollback_rules',
              'subscribe_manual', 'subscribe_manual_all', 'subscribe_del_node', 'subscribe_del_all',
              'create_backup', 'restore_backup', 'reset_config', 'update_passwall', 'update_xray']
    before = config_hash()
    for route in routes:
        status, body = request(sid, route)
        assert status == 405, (route, status, body[-500:])
        status, body = request(sid, route, {'token': 'wrong'})
        assert status == 403, (route, status, body[-500:])
    assert config_hash() == before
    print('PASS 29 write routes reject GET and invalid CSRF without changing configuration', flush=True)

    # A server-only UCI grant must never authorize a client action via type=server.
    readonly = login()
    ubus('revoke', {'ubus_rpc_session': readonly, 'scope': 'uci', 'objects': [['*', '*'], ['*', 'write'], ['passwall', 'write'], ['passwall_server', 'write']]})
    ubus('grant', {'ubus_rpc_session': readonly, 'scope': 'uci', 'objects': [['passwall', 'read'], ['passwall_server', 'read']]})
    for route in routes:
        if route == 'create_backup': continue  # Explicitly a read operation.
        status, body = post(readonly, route)
        assert status == 403, (route, status, body[-500:])
    ubus('grant', {'ubus_rpc_session': readonly, 'scope': 'uci', 'objects': [['passwall_server', 'write']]})
    status, body = post(readonly, 'update_config', type='server', id='global', data='{"remarks":"bypass"}')
    assert status == 403 and config_hash() == before, (status, body)
    print('PASS read-only permissions and client/server scope separation', flush=True)

    payload = "x';touch /tmp/http-security-injected;#"
    for route, key in [('server_status', 'id'), ('socks_status', 'id'), ('gen_client_config', 'id'),
                       ('server_log', 'id'), ('get_redir_log', 'id'), ('get_socks_log', 'name'), ('get_chinadns_log', 'flag'), ('ping_node', 'address')]:
        status, body = request(sid, route + '?' + urllib.parse.urlencode({key: payload}))
        assert status == 400, (route, status, body[-500:])
    for task in ('extract', 'move'):
        status, body = post(sid, 'update_xray', task=task, file='/etc/config/passwall')
        assert status == 200 and json.loads(body)['code'] == 1, (task, status, body)
    shell('ln -s /etc/config/passwall /tmp/xray_download.security-test')
    try:
        for task in ('extract', 'move'):
            status, body = post(sid, 'update_xray', task=task, file='/tmp/xray_download.security-test')
            assert status == 200 and json.loads(body)['code'] == 1, (task, status, body)
    finally:
        shell('rm -f /tmp/xray_download.security-test')
    assert config_hash() == before

    def upload(session, chunk, index=0, count=1, group='qa-import', upload_id=''):
        status, body = post(session, 'link_add_node', chunk=chunk, chunk_index=index, total_chunks=count, group=group, upload_id=upload_id)
        return status, json.loads(body)

    link = 'vless://00000000-0000-4000-8000-000000000001@127.0.0.1:1443?security=none&type=tcp#QA'
    status, result = upload(sid, link + '\nnot-a-link')
    assert status == 409 and result['message'] == 'invalid_link_input', (status, result)
    assert config_hash() == before, 'partial import survived a malformed link'
    assert upload(sid, 'x' * 8193)[0] == 409
    assert upload(sid, 'tail', index=1, count=2)[0] == 409
    request_before = shell('cat /tmp/passwall_switch/request')
    other = login()
    cut = len(link) // 2
    status, first = upload(sid, link[:cut], count=2, group=payload)
    assert status == 200, first
    status, second = upload(other, link[:cut], count=2, group='qa-second')
    assert status == 200 and first['upload_id'] != second['upload_id'], second
    assert upload(sid, link[cut:], index=1, count=2, group=payload, upload_id=second['upload_id'])[0] == 409
    status, result = upload(sid, link[cut:], index=1, count=2, group=payload, upload_id=first['upload_id'])
    assert status == 200 and result['imported'] == 1, (status, result)
    # The second upload cannot silently overwrite the newer configuration.
    status, result = upload(other, link[cut:], index=1, count=2, group='qa-second', upload_id=second['upload_id'])
    assert status == 409 and result['message'] == 'config_conflict', (status, result)
    status, result = upload(other, link, group='qa-second')
    assert status == 200 and result['imported'] == 1, (status, result)
    nodes = json.loads(shell("ubus call uci get '{\"config\":\"passwall\",\"type\":\"nodes\"}'"))['values']
    imported = [node for node in nodes.values() if node.get('group') in (payload, 'qa-second')]
    assert len(imported) == 2 and all(node['add_mode'] == '1' for node in imported), imported
    node_id = imported[0]['.name']
    before_group = config_hash()
    status, body = post(sid, 'reassign_group', ids=node_id + ',invalid.node', group='partial-change')
    assert status == 400 and config_hash() == before_group, (status, body)
    status, body = post(sid, 'reassign_group', ids=node_id, group=payload)
    assert status == 200, (status, body)
    assert shell('uci get passwall.' + node_id + '.group').strip() == payload
    assert shell('cat /tmp/passwall_switch/request') == request_before, 'link import unexpectedly restarted the service'
    assert shell('test ! -e /tmp/http-security-injected && test ! -e /tmp/links.conf && echo clean').strip() == 'clean'
    print('PASS command/path input rejection, atomic imports, session isolation, ordering and revision conflicts', flush=True)

    # Replace only the external update worker in this disposable guest; exercise
    # the real HTTP validation and UCI commit without fetching a subscription.
    shell('cp /usr/share/passwall/subscribe.lua /tmp/qa-subscribe-original\n' +
          "printf '%s' 'local f=assert(io.open(\"/tmp/qa-subscribe-invoked\",\"w\")); f:write(table.concat(arg,\" \")); f:close()' > /usr/share/passwall/subscribe.lua\n" +
          "uci set passwall.qa_sub_a=subscribe_list\nuci set passwall.qa_sub_a.url='https://example.test/old-a'\n" +
          "uci set passwall.qa_sub_b=subscribe_list\nuci set passwall.qa_sub_b.url='https://example.test/old-b'\nuci commit passwall")
    urls = ['https://example.test/?list=a,b&quote=\'$(touch /tmp/http-security-injected)', 'https://example.test/?other=c,d']
    before = config_hash()
    status, body = post(sid, 'subscribe_manual_all', sections='["qa_sub_a","qa_sub_b"]', urls='["https://example.test/new",""]')
    assert status == 400 and config_hash() == before, (status, body)
    status, body = post(sid, 'subscribe_manual_all', sections='["qa_sub_a","qa_sub_b"]', urls=json.dumps(urls))
    assert status == 200 and json.loads(body)['success'], (status, body)
    invoked = shell('for i in $(seq 1 20); do [ ! -f /tmp/qa-subscribe-invoked ] || { cat /tmp/qa-subscribe-invoked; break; }; sleep 0.1; done')
    assert invoked == 'start all manual', invoked
    for section, url in zip(('qa_sub_a', 'qa_sub_b'), urls):
        assert shell('uci -q get passwall.' + section + '.url').rstrip('\n') == url
    assert shell('test ! -e /tmp/http-security-injected && echo clean').strip() == 'clean'
    assert shell('cat /tmp/passwall_switch/request') == request_before
    print('PASS subscription JSON arrays preserve commas/quotes and reject invalid batches atomically', flush=True)
    shell("""lua - <<'LUA'
local api = require 'luci.passwall.api'
local value = [==[quoted ' " $(touch /tmp/http-security-injected) `touch /tmp/http-security-injected`]==]
api.sh_uci_set('passwall', 'qa_shell', nil, 'nodes')
api.sh_uci_set('passwall', 'qa_shell', 'value', value, true)
assert(api.sh_uci_get('passwall', 'qa_shell', 'value') == value)
assert(api.sh_uci_get('passwall', '@global[0]', 'enabled'))
assert(not pcall(api.sh_uci_set, 'passwall', 'bad.section', 'value', 'x', true))
api.sh_uci_del('passwall', 'qa_shell', nil, true)
assert(not api.fs.access('/tmp/http-security-injected'))
LUA
""")
    print('PASS shell UCI helpers preserve literal quotes, dollars and backticks', flush=True)
finally:
    shell('if [ -f /tmp/qa-subscribe-original ]; then mv /tmp/qa-subscribe-original /usr/share/passwall/subscribe.lua; fi\nrm -f /tmp/qa-subscribe-invoked')
    shell("printf '%s' " + shlex.quote(original) + ' | base64 -d > /etc/config/passwall')
    for session in sessions:
        ubus('destroy', {'ubus_rpc_session': session})
        shell('rm -rf /tmp/passwall-import-' + session)
