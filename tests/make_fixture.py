#!/usr/bin/env python3
"""Generate a fake 3x-ui-like SQLite fixture; contains NO real clients/keys."""
import json,sqlite3
from pathlib import Path
p=Path(__file__).with_name('fixture.db')
p.unlink(missing_ok=True)
c=sqlite3.connect(p)
c.executescript('''
CREATE TABLE settings (key TEXT, value TEXT);
CREATE TABLE inbounds (id INTEGER PRIMARY KEY, protocol TEXT, port INTEGER, enable INTEGER,
  listen TEXT, remark TEXT, settings TEXT, stream_settings TEXT, up INTEGER, down INTEGER);
CREATE TABLE clients (id INTEGER PRIMARY KEY, email TEXT, up INTEGER, down INTEGER);
CREATE TABLE hosts (id INTEGER PRIMARY KEY, inbound_id INTEGER, address TEXT, port INTEGER,
  remark TEXT, sni TEXT, security TEXT, group_id TEXT, updated_at INTEGER, created_at INTEGER);
''')
for name,val in {
 'webPort':'57875','webBasePath':'/admin-example/','webDomain':'203.0.113.42',
 'subPort':'2097','subPath':'/sub-example/','subJsonPath':'/json-example/',
 'subClashPath':'/clash-example/','subDomain':'203.0.113.42',
 'subURI':'https://203.0.113.42/sub-example/', 'webListen':'127.0.0.1',
}.items(): c.execute('INSERT INTO settings VALUES (?,?)',(name,val))
for i in range(1,13):c.execute('INSERT INTO clients VALUES (?,?,?,?)',(i,f'example-{i}',i*100,i*200))

def insert(i,protocol,port,net='',security='none',extra=None,conf=None,enabled=1):
    stream={'network':net,'security':security}
    if extra:stream.update(extra)
    c.execute('INSERT INTO inbounds VALUES (?,?,?,?,?,?,?,?,?,?)',(
        i,protocol,port,enabled, '127.0.0.1' if net in ('ws','xhttp','grpc') or protocol=='mtproto' else '',
        '🌳 Произвольное название '+str(i),json.dumps(conf or {},ensure_ascii=False),
        json.dumps(stream,ensure_ascii=False),1000+i,2000+i))

insert(1,'hysteria',443,'hysteria','tls',{'tlsSettings':{
    'serverName':'203.0.113.42','certificates':[{'certificateFile':'/old/cert.pem','keyFile':'/old/key.pem'}]}})
insert(2,'vless',10444,'xhttp','reality',{'xhttpSettings':{'path':'/xhttp'},
    'sockopt':{'acceptProxyProtocol':True},
    'realitySettings':{'serverNames':['www.amazon.com'],'target':'www.amazon.com:443','privateKey':'TEST-PLACEHOLDER-DO-NOT-USE'}})
insert(3,'vless',10451,'ws',extra={'wsSettings':{'path':'/ws-vless'}})
insert(4,'vless',13133,'tcp','reality',{'realitySettings':{
    'serverNames':['example.org'],'target':'example.org:443','privateKey':'TEST-PLACEHOLDER-DO-NOT-USE'}})
insert(5,'vmess',10452,'ws',extra={'wsSettings':{'path':'/ws-vmess'}})
insert(6,'tuic',8444,conf={'server':{'certificate':'/old/cert.pem','private_key':'/old/key.pem','sni':'203.0.113.42'}})
insert(7,'amneziawg',51821)
insert(8,'amneziawg',51822)
insert(9,'mtproto',10445,conf={'fakeTlsDomain':'www.samsung.com','proxyProtocolListener':True})
insert(10,'trojan',10453,'grpc',extra={'grpcSettings':{'serviceName':'trojan-example'}})
for i in (2,3,5,9,10):
    c.execute('INSERT INTO hosts VALUES (?,?,?,?,?,?,?,?,?,?)',
      (i,i,'203.0.113.42',443,'test host',None,'same',str(i),0,0))
c.commit();c.close()
print('Generated test fixture:',p)
