#!/usr/bin/env python3
"""Offline IP↔domain tests; use a private DB supplied locally, never upload it."""
from pathlib import Path
import hashlib, json, sqlite3, subprocess, sys, tempfile

if len(sys.argv)!=2:
    raise SystemExit('usage: python3 test_db_tool.py /path/to/private.db')
src=Path(sys.argv[1]).resolve()
helper=Path(__file__).with_name('db_tool.py')
sha=lambda p: hashlib.sha256(Path(p).read_bytes()).hexdigest()
start=sha(src)
def call(*args):
    return subprocess.run([sys.executable,str(helper),*map(str,args)],check=True,capture_output=True,text=True).stdout

def cols(p,table):
    with sqlite3.connect(p) as c:
        names=[r[1] for r in c.execute(f'pragma table_info({table})')]
        return [dict(zip(names,r)) for r in c.execute(f'select * from {table} order by id')]

with tempfile.TemporaryDirectory() as temp:
    d=Path(temp)
    domain=d/'domain.db'
    ip=d/'ip.db'
    params=('--cert','/tmp/valid/fullchain.pem','--key','/tmp/valid/privkey.pem')
    call('prepare','--db',src,'--out',domain,'--domain','vpn.example.org',*params)
    # Simulate a manually configured unrelated host, which a later switch must preserve.
    with sqlite3.connect(domain) as c:
        c.execute("update hosts set address='other.example.org' where id=(select min(id) from hosts)")
        c.commit()
    call('prepare','--db',domain,'--out',ip,'--domain','8.8.8.8','--old-host','vpn.example.org',*params)
    for p in (domain,ip):
        with sqlite3.connect(p) as c:
            assert c.execute('pragma integrity_check').fetchone()[0]=='ok'
        assert len(cols(p,'clients'))==len(cols(src,'clients'))
        assert cols(p,'clients')==cols(src,'clients'), 'client table changed unexpectedly'
        a=cols(src,'inbounds');b=cols(p,'inbounds')
        for x,y in zip(a,b):
            for k in ('id','remark','port','protocol','enable','up','down','total','expiry_time'):
                if k in x: assert x[k]==y[k],f'{k} changed'
            if x['remark']=='VPN':
                assert json.loads(x['settings'])==json.loads(y['settings'])
                before=json.loads(x['stream_settings'])
                after=json.loads(y['stream_settings'])
                assert after['realitySettings']['serverNames']==['dl.google.com']
                assert after['realitySettings']['target']=='dl.google.com:443'
                assert after['realitySettings']['privateKey']==before['realitySettings']['privateKey']
                assert x['port']==y['port'] and y['listen']=='127.0.0.1'
        old_settings={k:v for k,v in sqlite3.connect(src).execute('select key,value from settings')}
        new_settings={k:v for k,v in sqlite3.connect(p).execute('select key,value from settings')}
        for k in ('webBasePath','subPath','subJsonPath','subClashPath','webPort','subPort'):
            assert old_settings[k]==new_settings[k],f'{k} path or port changed'
    with sqlite3.connect(ip) as c:
        addresses=[r[0] for r in c.execute('select address from hosts order by id')]
        assert 'other.example.org' in addresses and '8.8.8.8' in addresses
        assert 'vpn.example.org' not in addresses
    for p,host in [(domain,'vpn.example.org'),(ip,'8.8.8.8')]:
        html=d/f'http-{host}.conf'; stream=d/f'stream-{host}.conf'
        call('nginx','--db',p,'--domain',host,*params,'--http-out',html,'--stream-out',stream)
        http=html.read_text(); routing=stream.read_text()
        assert f'server_name {host}' in http
        assert 'proxy_ssl_verify off;' in http and 'proxy_ssl_verify on;' not in http
        assert 'ssl_preread on;' in routing and 'proxy_protocol on;' in routing
        assert 'dl.google.com 127.0.0.1:13133;' in routing
        assert 'grpc_pass' in http and '10446' in http
        assert 'root /var/www/3x-ui-landing;' in http
        assert 'location = / {' in http and 'location = /index.html {' in http
        assert 'error_page 404 /404.html;' in http and 'location = /404.html' in http
    assert sha(src)==start, 'source db modified'
print('PASS: IP↔domain, 12 clients, VLESS REALITY, stats, paths, Nginx, source intact.')
