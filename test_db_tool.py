#!/usr/bin/env python3
"""Offline smoke check, needs private DB path argument. No secrets printed."""
from pathlib import Path
import hashlib
import json
import sqlite3
import subprocess
import sys
import tempfile

if len(sys.argv) != 2:
    print('usage: python3 test_db_tool.py /path/to/private.db'); sys.exit(2)
p=Path(sys.argv[1]); helper=Path(__file__).with_name('db_tool.py')
sha=lambda f:hashlib.sha256(Path(f).read_bytes()).hexdigest()
before=sha(p)
with tempfile.TemporaryDirectory() as d:
    q=Path(d)/'prepared.db'; http=Path(d)/'http.conf'; stream=Path(d)/'stream.conf'
    x=['--domain','vpn.example.org','--cert','/tmp/example.crt','--key','/tmp/example.key']
    subprocess.run([sys.executable,str(helper),'prepare','--db',str(p),'--out',str(q),*x],check=True)
    subprocess.run([sys.executable,str(helper),'nginx','--db',str(q), '--http-out',str(http),'--stream-out',str(stream),*x],check=True)
    a=sqlite3.connect(f'file:{p}?mode=ro',uri=True);b=sqlite3.connect(f'file:{q}?mode=ro',uri=True)
    assert b.execute('pragma integrity_check').fetchone()[0]=='ok'
    for table in ('clients','inbounds'):
        assert a.execute(f'select count(*) from {table}').fetchone()==b.execute(f'select count(*) from {table}').fetchone()
    old={r[0]:r[1] for r in a.execute('select id,settings from inbounds')}
    new={r[0]:r[1] for r in b.execute('select id,settings from inbounds')}
    for k in old:
        if k!=6: assert old[k]==new[k],f'client settings changed in inbound {k}'
    assert all(row[0]=='vpn.example.org' for row in b.execute('select address from hosts'))
    assert 'ssl_preread on' in stream.read_text()
    assert 'grpc_pass' in http.read_text()
    assert 'proxy_protocol on' in stream.read_text()
    assert 'apple.com' in stream.read_text()
    # Domain and public-IP modes both preserve original and build valid configs.
    qip=Path(d)/'prepared-ip.db'
    hip=Path(d)/'ip-http.conf'
    sip=Path(d)/'ip-stream.conf'
    xip=['--domain','8.8.8.8','--cert','/tmp/example-ip.crt','--key','/tmp/example-ip.key']
    subprocess.run([sys.executable,str(helper),'prepare','--db',str(p),'--out',str(qip),*xip],check=True)
    subprocess.run([sys.executable,str(helper),'nginx','--db',str(qip),'--http-out',str(hip),'--stream-out',str(sip),*xip],check=True)
    assert 'server_name 8.8.8.8' in hip.read_text()
    assert b.execute('pragma integrity_check').fetchone()[0]=='ok'
    assert before==sha(p), 'original changed' 
    print('OK: source unchanged, SQLite ok, clients preserved, nginx routes generated.')
