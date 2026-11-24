#!/usr/bin/env python3
"""Optional TUIC-disable staging on an isolated DB copy; no version pin."""
import hashlib,sqlite3,subprocess,sys,tempfile
from pathlib import Path
root=Path(__file__).resolve().parents[1]
if len(sys.argv) < 2:
    subprocess.run([sys.executable,str(root/'tests'/'make_fixture.py')],check=True,
                   stdout=subprocess.DEVNULL)
src=Path(sys.argv[1] if len(sys.argv)>1 else str(root/'tests'/'fixture.db'))
h=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
original=h(src)
with tempfile.TemporaryDirectory() as d:
    out=Path(d)/'prepared.db'
    subprocess.run([sys.executable,str(root/'db_tool.py'),'prepare','--db',str(src),
     '--out',str(out),'--domain','vpn.example.com',
     '--cert','/root/cert/ip/fullchain.pem','--key','/root/cert/ip/privkey.pem',
     '--disable-tuic'],check=True,capture_output=True,text=True)
    with sqlite3.connect(src) as before, sqlite3.connect(out) as after:
        rows0=before.execute("SELECT id,enable FROM inbounds WHERE lower(protocol)='tuic'").fetchall()
        rows1=after.execute("SELECT id,enable FROM inbounds WHERE lower(protocol)='tuic'").fetchall()
        assert {i for i,_ in rows0}=={i for i,_ in rows1}
        assert all(not val for _,val in rows1)
        assert before.execute('SELECT * FROM clients').fetchall()==after.execute('SELECT * FROM clients').fetchall()
assert h(src)==original
print('PASS: TUIC optional disable in copy; client table and source preserved.')
