#!/usr/bin/env python3
"""Run the standalone switch's data edits against an isolated copy, no root needed."""
import json, pathlib, re, sqlite3, subprocess, sys, tempfile
root=pathlib.Path(__file__).resolve().parent
s=(root/'reality-443.sh').read_text()
blocks=re.findall(r"python3 - [^\n]+ <<'PY'\n(.*?)\nPY",s,re.S)
assert len(blocks)==4, 'Expected exactly 4 embedded Python blocks'
source=pathlib.Path(sys.argv[1])
with tempfile.TemporaryDirectory() as td:
    td=pathlib.Path(td)
    addr='45.38.23.129'
    import hashlib
    sha=lambda p:hashlib.sha256(pathlib.Path(p).read_bytes()).hexdigest()
    sha_before=sha(source)
    with sqlite3.connect(source) as c, sqlite3.connect(td/'db-before.sqlite') as out:
        c.backup(out)
    db=td/'db-before.sqlite'
    # Generate an old-style nginx SNI route from the unmodified sample database.
    stream=td/'nginx-before.conf'
    subprocess.run([sys.executable,str(root/'db_tool.py'),'nginx','--db',str(db),'--domain',addr,'--cert','/tmp/a.crt','--key','/tmp/a.key', '--http-out',str(td/'http.conf'), '--stream-out',str(stream)],check=True,capture_output=True)
    # 1st embedded Python snippet checks original route.
    subprocess.run([sys.executable,'-c',blocks[0],str(stream)],check=True)
    subprocess.run([sys.executable,'-c',blocks[2],str(db),addr],check=True)
    subprocess.run([sys.executable,'-c',blocks[3],str(stream),str(td/'nginx-after.conf')],check=True)
    with sqlite3.connect(source) as c0,sqlite3.connect(db) as c:
        clients0=list(c0.execute('select * from clients order by id'))
        clients=list(c.execute('select * from clients order by id'))
        assert clients==clients0
        orig=dict((x[0],x[1:]) for x in c0.execute('select remark,settings,stream_settings,listen,port,up,down from inbounds'))
        new=dict((x[0],x[1:]) for x in c.execute('select remark,settings,stream_settings,listen,port,up,down from inbounds'))
        assert orig.keys()==new.keys()
        for remark in orig:
            if remark!='VPN': assert orig[remark]==new[remark],f'Changed unrelated inbound: {remark}'
        before=json.loads(orig['VPN'][1]);after=json.loads(new['VPN'][1]);
        assert before['realitySettings']['privateKey']==after['realitySettings']['privateKey']
        assert after['realitySettings']['target']=='dl.google.com:443'
        assert after['realitySettings']['serverNames']==['dl.google.com']
        assert new['VPN'][2]=='127.0.0.1'
        hosts=list(c.execute('select address,port,sni from hosts where inbound_id=(select id from inbounds where remark="VPN")'))
        assert hosts==[(addr,443,'dl.google.com')]
        assert c.execute('pragma integrity_check').fetchone()[0]=='ok'
    text=(td/'nginx-after.conf').read_text()
    assert 'dl.google.com 127.0.0.1:13133;' in text
    assert 'apple.com 127.0.0.1:13133;' not in text
    assert sha_before==sha(source)
print('PASS: One-shot migration on isolated DB and Nginx, other inbounds and credentials intact')
