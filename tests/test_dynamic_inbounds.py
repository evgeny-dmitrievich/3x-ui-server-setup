#!/usr/bin/env python3
"""Regression: 3, 10 and 15 inbound counts, renamed entries, nonstandard ports."""
import hashlib
import json
import sqlite3
import subprocess
import sys
import tempfile
from pathlib import Path

root=Path(__file__).resolve().parents[1]
if len(sys.argv) < 2:
    subprocess.run([sys.executable,str(root/'tests'/'make_fixture.py')],check=True,
                   stdout=subprocess.DEVNULL)
source=Path(sys.argv[1] if len(sys.argv)>1 else str(root/'tests'/'fixture.db'))
tool=root/'db_tool.py'
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
original_hash=sha(source)

def call(*args):
    p=subprocess.run([sys.executable,str(tool),*map(str,args)],capture_output=True,text=True)
    if p.returncode: raise AssertionError(f'Command failed: {p.stderr}')
    return p.stdout

def copy(src,dst):
    with sqlite3.connect(src) as a, sqlite3.connect(dst) as b:a.backup(b)

def load_inbounds(p):
    with sqlite3.connect(p) as c:
        return {x[0]:x[1:] for x in c.execute('SELECT id,remark,port,protocol,settings FROM inbounds ORDER BY id')}

with tempfile.TemporaryDirectory() as td:
    tmp=Path(td)
    for size in (3,10,15):
        src=tmp/f'source-{size}.db'
        copy(source,src)
        with sqlite3.connect(src) as c:
            if size==3:
                keep=[1,4,3]
                c.execute('DELETE FROM inbounds WHERE id NOT IN (?,?,?)',keep)
                c.execute('DELETE FROM hosts WHERE inbound_id NOT IN (?,?,?)',keep)
            elif size==15:
                for i in range(5):
                    c.execute('''INSERT INTO inbounds (remark,protocol,port,enable,listen,settings,stream_settings,up,down)
                       SELECT ?,protocol,?,enable,listen,settings,stream_settings,up,down FROM inbounds WHERE id=?''',
                       (f'🧪 Добавлено {i}', 17010+i, 3 if i%2 else 5))
                # Change the new WS paths, so they can all coexist on 443.
                for row_id,ss in c.execute('SELECT id,stream_settings FROM inbounds WHERE port BETWEEN 17010 AND 17014').fetchall():
                    s=json.loads(ss)
                    if s.get('network')=='ws': s['wsSettings']['path']=f'/additional-{row_id}'
                    c.execute('UPDATE inbounds SET stream_settings=? WHERE id=?',(json.dumps(s),row_id))
            c.execute("UPDATE inbounds SET remark='🌿 Любое имя — с пробелами' WHERE port=13133")
            c.commit()
        count=sqlite3.connect(src).execute('SELECT count(*) FROM inbounds').fetchone()[0]
        assert count==size,(size,count)
        inspect=json.loads(call('inspect','--db',src))
        assert inspect['inbounds']==size
        assert inspect['web_port']==57875
        assert inspect['clients']==12
        assert inspect['sni_routes'],size
        original=load_inbounds(src)
        out=tmp/f'prepared-{size}.db'
        params=['--domain','vpn.example.net','--cert','/root/cert/ip/fullchain.pem','--key','/root/cert/ip/privkey.pem']
        call('prepare','--db',src,'--out',out,*params)
        assert sqlite3.connect(out).execute('PRAGMA integrity_check').fetchone()[0]=='ok'
        with sqlite3.connect(src) as x,sqlite3.connect(out) as y:
            assert x.execute('SELECT * FROM clients').fetchall()==y.execute('SELECT * FROM clients').fetchall()
            assert x.execute('SELECT id,remark,port,protocol,enable,up,down FROM inbounds').fetchall()==y.execute('SELECT id,remark,port,protocol,enable,up,down FROM inbounds').fetchall()
            assert x.execute("SELECT value FROM settings WHERE key='webBasePath'").fetchone()==y.execute("SELECT value FROM settings WHERE key='webBasePath'").fetchone()
            orig_reality=json.loads(x.execute('SELECT stream_settings FROM inbounds WHERE port=13133').fetchone()[0])['realitySettings']
            new_reality=json.loads(y.execute('SELECT stream_settings FROM inbounds WHERE port=13133').fetchone()[0])['realitySettings']
            assert orig_reality == new_reality, 'REALITY SNI/private key modified'
        http=tmp/f'http-{size}.conf';stream=tmp/f'stream-{size}.conf'
        call('nginx','--db',out,*params,'--http-out',http,'--stream-out',stream)
        h=http.read_text(); st=stream.read_text()
        # WebSocket support belongs to the panel location itself, not just VPN WS.
        assert 'map $http_upgrade $connection_upgrade' in h
        panel=h.split(f"location ^~ {inspect['web_path']}", 1)[1].split('}',1)[0]
        assert 'proxy_pass https://127.0.0.1:57875;' in panel
        for directive in ('proxy_http_version 1.1;',
                          'proxy_set_header Upgrade $http_upgrade;',
                          'proxy_set_header Connection $connection_upgrade;'):
            assert panel.count(directive) == 1, directive
        assert 'proxy_ssl_verify off;' in h
        assert 'proxy_ssl_verify on;' not in h
        assert 'root /var/www/3x-ui-landing' in h
        assert 'example.org 127.0.0.1:13133' in st
        if size>=10:
            assert 'www.amazon.com' in st and 'www.samsung.com' in st
            assert 'proxy_protocol on;' in st
        if size==15:
            assert 'additional-' in h
        assert sha(src)!=sha(out)
        print('PASS:',size,'inbounds; generated',len(st),'stream bytes,',len(h),'http bytes')
assert original_hash==sha(source),'Original source DB unexpectedly changed'
print('PASS: DB source unchanged; 3/10/15 configurations')
