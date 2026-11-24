#!/usr/bin/env python3
# PROJECT_VERSION=2.6.0
"""Offline regression: renamed inbounds, certificate paths, TUIC staging."""
from pathlib import Path
import hashlib, json, sqlite3, subprocess, sys, tempfile
if len(sys.argv) != 2: raise SystemExit('usage: python3 test_pre_import.py source.db')
src=Path(sys.argv[1])
script=Path(__file__).with_name('db_tool.py')
sha=lambda f: hashlib.sha256(Path(f).read_bytes()).hexdigest()
h0=sha(src)
with tempfile.TemporaryDirectory() as td:
    renamed=Path(td)/'renamed.db'
    disabled=Path(td)/'disabled.db'
    enabled=Path(td)/'enabled.db'
    with sqlite3.connect(src) as c, sqlite3.connect(renamed) as d: c.backup(d)
    with sqlite3.connect(renamed) as c:
        for port,rem in [(13133,'🔄 Резервный — Reality'),(10444,'🟢 Основной — на каждый день'),
                         (10451,'🌐 Универсальный'),(10452,'🧩 Для старых приложений'),
                         (10453,'🔒 Защищённое соединение'),(10445,'💬 Только для Telegram')]:
            c.execute('UPDATE inbounds SET remark=? WHERE port=?', (rem,port))
        c.commit()
    def cmd(*argv):
        return subprocess.run([sys.executable,str(script),*map(str,argv)],check=True,capture_output=True,text=True)
    cmd('inspect','--db',renamed)
    original_renamed_hash=sha(renamed)
    for out, disable in [(disabled,True),(enabled,False)]:
        args=['prepare','--db',renamed,'--out',out,'--domain','vpn.example.com',
              '--cert','/root/cert/vpn.example.com/fullchain.pem',
              '--key','/root/cert/vpn.example.com/privkey.pem']
        if disable: args.append('--disable-tuic')
        cmd(*args)
        with sqlite3.connect(out) as c:
            assert c.execute('pragma integrity_check').fetchone()[0]=='ok'
            assert c.execute("select count(*) from clients").fetchone()[0]==12
            t=c.execute("select enable,settings from inbounds where port=8444 and protocol='tuic'").fetchone()
            assert t[0] == (0 if disable else 1)
            assert json.loads(t[1])['server']['certificate']=='/root/cert/vpn.example.com/fullchain.pem'
            h=c.execute("select stream_settings from inbounds where port=443 and protocol='hysteria'").fetchone()
            assert json.loads(h[0])['tlsSettings']['certificates'][0]['certificateFile']=='/root/cert/vpn.example.com/fullchain.pem'
            assert c.execute('select remark from inbounds where port=10444').fetchone()[0]=='🟢 Основной — на каждый день'
    assert sha(renamed)==original_renamed_hash
assert sha(src)==h0
print('PASS: renamed inbounds, certificate replacement, clients, optional TUIC disabled, source unchanged')
