#!/usr/bin/env python3
"""Exercise installed LuCI handlers in a disposable guest (no external service)."""
import argparse
import base64
from html.parser import HTMLParser
import json
import re
import shlex
import subprocess
import urllib.parse

parser=argparse.ArgumentParser();parser.add_argument('--ssh-port',type=int,default=2322);args=parser.parse_args()
SSH=['ssh','-p',str(args.ssh_port),'-o','BatchMode=yes','-o','ConnectTimeout=3','-o','StrictHostKeyChecking=no','-o','UserKnownHostsFile=/dev/null','-o','LogLevel=ERROR','root@127.0.0.1']
def shell(code): return subprocess.check_output(SSH+['/bin/sh'],input=code.encode()).decode()
def ubus(method,data): return json.loads(shell('ubus call session '+method+' '+shlex.quote(json.dumps(data))) or '{}')
sid=ubus('login',{'username':'root','password':''})['ubus_rpc_session']
token='qemu-config-transaction-test'
ubus('set',{'ubus_rpc_session':sid,'values':{'token':token}})
def request(path,data=None):
    cmd=['curl','--max-time','45','-sS','-b','sysauth_http='+sid,'-D','/tmp/pw-http-headers','-o','/tmp/pw-http-body']
    if data is not None: cmd+=['--data',urllib.parse.urlencode(data,doseq=True)]
    config='url = '+json.dumps('http://127.0.0.1/cgi-bin/luci/admin/services/passwall/'+path)+'\n'
    cmd+=['--config','-']
    result=shell("printf '%s' "+shlex.quote(config)+' | '+shlex.join(cmd)+'\nhead -n 1 /tmp/pw-http-headers\nbase64 /tmp/pw-http-body')
    status,body=result.split('\n',1)
    return int(status.split()[1]),base64.b64decode(body)
class Form(HTMLParser):
    def __init__(self): super().__init__();self.fields={};self.select=None;self.multiple=False;self.options=[];self.option=None;self.textarea=None
    def handle_starttag(self,tag,attrs):
        a=dict(attrs)
        if 'data-ui-widget' in a:
            widget=json.loads(a['data-ui-widget']);kind,value,options=widget[0],widget[1],widget[-1]
            if isinstance(options,dict) and options.get('name'):
                if kind=='Checkbox':
                    self.fields[options['hiddenname']]='1'
                    if value==options['value_enabled']: self.fields[options['name']]=value
                elif value is not None: self.fields[options['name']]=value
        if tag=='input' and a.get('name') and a.get('type') not in ('submit','button','file','reset'):
            if a.get('type') not in ('checkbox','radio') or 'checked' in a: self.fields[a['name']]=a.get('value','')
        if tag=='select': self.select=a.get('name');self.multiple='multiple' in a;self.options=[]
        if tag=='option': self.option=[a.get('value',''),'selected' in a];self.options.append(self.option)
        if tag=='textarea' and a.get('name'): self.textarea=a['name'];self.fields[self.textarea]=''
    def handle_data(self,data):
        if self.textarea: self.fields[self.textarea]+=data
    def handle_endtag(self,tag):
        if tag=='select' and self.select:
            values=[o[0] for o in self.options if o[1]]
            if not values and self.options and not self.multiple: values=[self.options[0][0]]
            if values: self.fields[self.select]=values if self.multiple else values[0]
            self.select=None
        if tag=='textarea': self.textarea=None
try:
    status,body=request('settings');assert status==200,body[-2000:]
    assert b'name="passwall_revision_passwall"' in body
    # Use a simple device form so valid save and reload can be checked end to end.
    before_request=shell('cat /tmp/passwall_switch/request 2>/dev/null || true')
    status,body=request('plus_create',{'token':token,'kind':'device'});assert status in (200,302),body
    location=shell("sed -n 's/^[Ll]ocation: //p' /tmp/pw-http-headers").strip()
    path=location.split('/passwall/',1)[1]
    node=path.rsplit('/',1)[1]
    status,body=request(path);assert status==200,body[-2000:]
    form=Form();form.feed(body.decode());fields=form.fields
    fields['token']=token;fields['cbi.submit']='1'
    remarks=next((k for k in fields if k.endswith('.remarks')),None)
    assert remarks,(path,sorted(fields),body[-1000:])
    fields[remarks]='transaction-test-saved'
    fields.pop(remarks.rsplit('.',1)[0]+'.bind_enable',None)
    status,body=request(path,fields)
    assert status==200 and '配置已变化' not in body.decode(),body[-2000:]
    assert shell('uci -q get '+shlex.quote('passwall.'+node+'.remarks')).strip()=='transaction-test-saved'
    assert shell('cat /tmp/passwall_switch/request 2>/dev/null || true')==before_request,'Save unexpectedly restarted the service'
    status,body=request(path);form=Form();form.feed(body.decode());fields=form.fields
    fields['token']=token;fields['cbi.submit']='1';fields[remarks]='stale-overwrite'
    shell("uci set passwall."+node+".remarks='newer-cloud-value'\nuci commit passwall")
    status,body=request(path,fields)
    assert '配置已变化' in body.decode(),body[-2000:]
    assert shell('uci -q get '+shlex.quote('passwall.'+node+'.remarks')).strip()=='newer-cloud-value'
    # Apply must schedule the existing protected restart after the lock is gone.
    status,body=request(path);form=Form();form.feed(body.decode());apply_fields=form.fields
    apply_fields.update({'token':token,'cbi.submit':'1','cbi.apply':'1'})
    previous=shell('cat /tmp/passwall_switch/request')
    status,body=request(path,apply_fields);assert status==200,(status,body[-1000:])
    settled=shell("for i in $(seq 1 60); do if [ \"$(cat /tmp/passwall_switch/phase)\" = idle ] && [ \"$(cat /tmp/passwall_switch/request)\" != "+shlex.quote(previous.strip())+" ]; then echo settled; break; fi; sleep 1; done")
    assert settled.strip()=='settled','Apply did not finish through the protected lifecycle'
    status,_=request('restore_backup');assert status==405,status
    status,_=request('restore_backup',{'token':'invalid','type':'client'});assert status==403,status
    status,data=request('create_backup',{'token':token});assert status==200 and data[:2]==b'\x1f\x8b',(status,data[:500])
    status,body=request('restore_backup',{'token':token,'type':'client','filename':'../../etc/shadow','chunk_index':0,'total_chunks':1,'chunk':base64.b64encode(b'invalid').decode()})
    assert status==409 and json.loads(body)['message']=='invalid_gzip',(status,body)
    ubus('revoke',{'ubus_rpc_session':sid,'scope':'uci','objects':[['*','*'],['passwall','write'],['*','write']]})
    status,_=request('restore_backup',{'token':token,'type':'client'});assert status==403,status
    before=shell('sha256sum /etc/config/passwall')
    request(path,fields)
    assert shell('sha256sum /etc/config/passwall')==before,'read-only form changed configuration'
    # CBI's raw-source repair must not bypass the transaction or permissions.
    original=shell('base64 /etc/config/passwall')
    try:
        shell("printf 'invalid uci config!\\n' > /etc/config/passwall")
        before=shell('sha256sum /etc/config/passwall')
        request('settings',{'token':token,'cbi.submit':'1','cbi.source':"config global 'global'\n"})
        assert shell('sha256sum /etc/config/passwall')==before,'raw CBI source bypassed authorization'
    finally:
        shell("printf '%s' "+shlex.quote(original)+' | base64 -d > /etc/config/passwall')
    print('PASS installed LuCI save/apply, stale-page conflict, backup download, invalid archive, CSRF, read-only permissions and raw-source protection')
finally:
    # Guest is disposable; remove only the test policy we created.
    if 'node' in globals(): shell('uci -q delete '+shlex.quote('passwall.'+node)+'\nuci commit passwall')
    ubus('destroy',{'ubus_rpc_session':sid})
