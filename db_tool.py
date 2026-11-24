#!/usr/bin/env python3
"""Version-agnostic, data-driven 3x-ui SQLite -> nginx reconciler.

Only edits a NEW SQLite copy. Unknown protocols are preserved, not guessed at.
Never prints UUIDs, private keys, passwords, tokens, or subscription URLs.
"""
import argparse
import ipaddress
import json
import pathlib
import re
import secrets
import sqlite3
import sys
import time
from urllib.parse import urlparse

PROJECT_VERSION = '2.8.0'
HOST_RE = re.compile(r'^[a-z0-9](?:[a-z0-9.-]{0,251}[a-z0-9])?$', re.I)
PATH_RE = re.compile(r'^/[a-zA-Z0-9_./~%-]*$')
CERT_RE = re.compile(r'^/[A-Za-z0-9_.\-/]+$')
UDP_ONLY = {'hysteria', 'hysteria2', 'tuic', 'amneziawg', 'wireguard'}


def public_host(text):
    text = (text or '').strip().lower()
    try:
        ip = ipaddress.ip_address(text)
    except ValueError:
        if not HOST_RE.fullmatch(text) or '..' in text or '.' not in text:
            raise ValueError('Некорректный домен')
        return text
    if ip.version != 4 or not ip.is_global:
        raise ValueError('Ожидается публичный IPv4')
    return str(ip)


def conn_open(filename, readonly=True):
    path = pathlib.Path(filename).resolve()
    if not path.is_file():
        raise ValueError('SQLite-файл не найден')
    c = sqlite3.connect(f'file:{path}?mode={"ro" if readonly else "rw"}', uri=True)
    c.row_factory = sqlite3.Row
    if c.execute('PRAGMA integrity_check').fetchone()[0] != 'ok':
        c.close()
        raise ValueError('SQLite integrity_check не прошла')
    tables = {r[0] for r in c.execute("SELECT name FROM sqlite_master WHERE type='table'")}
    if not {'settings', 'inbounds'}.issubset(tables):
        c.close()
        raise ValueError('Не найдены таблицы settings/inbounds панели 3x-ui')
    return c


def has_table(c, table):
    return bool(c.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", (table,)).fetchone())


def columns(c, table):
    return {r['name'] for r in c.execute(f'PRAGMA table_info({table})')}


def settings(c):
    return {r['key']: r['value'] for r in c.execute('SELECT key,value FROM settings')}


def set_setting(c, key, value):
    if c.execute('SELECT 1 FROM settings WHERE key=?', (key,)).fetchone():
        c.execute('UPDATE settings SET value=? WHERE key=?', (str(value), key))
    else:
        c.execute('INSERT INTO settings(key,value) VALUES(?,?)', (key, str(value)))


def check_path(value, label, *, allow_root=False):
    if not isinstance(value, str) or not value.startswith('/') or not PATH_RE.fullmatch(value) or '..' in value or '//' in value:
        raise ValueError(f'Недопустимый путь {label} в настройках панели')
    if value == '/' and not allow_root:
        raise ValueError(f'Путь {label} совпадает с главной страницей заглушки')
    return value


def port_int(value, label):
    try: result = int(value)
    except (TypeError, ValueError): raise ValueError(f'Некорректный {label}') from None
    if not 1 <= result <= 65535:
        raise ValueError(f'Некорректный {label}')
    return result


def load_obj(value, label):
    try: parsed = json.loads(value or '{}')
    except (ValueError, TypeError): raise ValueError(f'Некорректный JSON: {label}') from None
    if not isinstance(parsed, dict):
        raise ValueError(f'Ожидался JSON-объект: {label}')
    return parsed


def source_address(sc):
    """Only infer addresses explicitly configured for this server.

    Never replace a completely unrelated third-party address by assumption.
    """
    for key in ('subDomain', 'webDomain'):
        val = (sc.get(key) or '').strip()
        if val and val not in ('127.0.0.1', 'localhost'):
            return val
    for key in ('subURI', 'subJsonURI', 'subClashURI'):
        try:
            v = urlparse(sc.get(key) or '').hostname
            if v and v not in ('127.0.0.1', 'localhost'):
                return v
        except ValueError:
            pass
    return None


def row_data(c):
    fields = columns(c, 'inbounds')
    required = {'id', 'protocol', 'port', 'settings'}
    if not required.issubset(fields):
        raise ValueError('В таблице inbounds отсутствуют обязательные поля')
    rows = []
    for r in c.execute('SELECT * FROM inbounds ORDER BY id'):
        protocol = str(r['protocol'] or '').lower()
        raw_s = r['stream_settings'] if 'stream_settings' in fields else '{}'
        rows.append({
            'id': r['id'], 'protocol': protocol, 'port': port_int(r['port'], 'порт inbound'),
            'enabled': bool(r['enable']) if 'enable' in fields else True,
            'listen': (r['listen'] or '') if 'listen' in fields else '',
            'remark': (r['remark'] or '') if 'remark' in fields else '',
            'stream': load_obj(raw_s, 'stream_settings'),
            'config': load_obj(r['settings'], 'settings'),
        })
    return rows


def sni_domain(val):
    if not isinstance(val, str): return None
    v = val.strip().lower()
    if not v or not HOST_RE.fullmatch(v) or '..' in v or '.' not in v:
        return None
    return v


def get_snis(r):
    if r['protocol'] == 'mtproto':
        d = sni_domain(r['config'].get('fakeTlsDomain'))
        return [d] if d else []
    s = r['stream']
    if str(s.get('security', '')).lower() != 'reality':
        return []
    val = s.get('realitySettings', {}).get('serverNames', [])
    if not isinstance(val, list): return []
    return list(dict.fromkeys(filter(None, (sni_domain(x) for x in val))))


def network(r):
    return str(r['stream'].get('network', '')).lower()


def http_route(r):
    """Return a web route when it can be proxied through a local TLS terminator."""
    if r['protocol'] in UDP_ONLY or r['protocol'] == 'mtproto': return None
    s = r['stream']; net = network(r); sec = s.get('security', 'none')
    if sec == 'reality': return None
    if net == 'ws':
        raw = (s.get('wsSettings') or {}).get('path')
        if not raw: return None
        p = check_path(raw.split('?',1)[0], 'wsSettings.path')
        return {'kind':'ws', 'path':p, 'upstream':r['port'], 'tls': sec == 'tls', 'id':r['id']}
    if net == 'grpc':
        service = (s.get('grpcSettings') or {}).get('serviceName')
        if not service: return None
        p = check_path('/'+service.lstrip('/'), 'grpcSettings.serviceName')
        return {'kind':'grpc', 'path':p.rstrip('/'), 'upstream':r['port'], 'tls':sec == 'tls', 'id':r['id']}
    if net == 'xhttp':
        raw = (s.get('xhttpSettings') or {}).get('path')
        if not raw: return None
        p = check_path(raw.split('?',1)[0], 'xhttpSettings.path')
        return {'kind':'xhttp', 'path':p, 'upstream':r['port'], 'tls':sec == 'tls', 'id':r['id']}
    return None


def describe(c, public=None):
    sc = settings(c)
    if not sc.get('webPort') or not sc.get('webBasePath'):
        raise ValueError('Не заданы webPort или webBasePath. Их необходимо указать в панели.')
    web_port = port_int(sc['webPort'], 'webPort')
    web_path = check_path(sc['webBasePath'], 'webBasePath')
    sub_port = port_int(sc['subPort'], 'subPort') if sc.get('subPort') else None
    sub_paths = []
    if sub_port:
        for k in ('subPath', 'subJsonPath', 'subClashPath'):
            if sc.get(k):
                p = check_path(sc[k], k)
                if p not in sub_paths: sub_paths.append(p)
    rows = row_data(c)
    used_ports = {web_port, 443}
    if sub_port: used_ports.add(sub_port)
    used_ports.update(x['port'] for x in rows)
    http_port = 10446 if 10446 not in used_ports else next((x for x in range(14000,16000) if x not in used_ports), None)
    if http_port is None: raise ValueError('Не найден свободный внутренний порт Nginx HTTPS')
    used_ports.add(http_port)

    stream_candidates = []
    web_routes = []
    notes = []
    for r in rows:
        if not r['enabled']: continue
        if r['protocol'] in UDP_ONLY: continue
        if r['port'] == 443:
            raise ValueError('В базе есть активный TCP inbound на 443; Nginx тоже должен слушать 443. Разреши конфликт порта вручную.')
        snis = get_snis(r)
        for name in snis:
            stream_candidates.append({'sni':name, 'port':r['port'], 'id':r['id'],
                'proxy': (r['protocol']=='mtproto' and r['config'].get('proxyProtocolListener') is True)
                or (r['stream'].get('sockopt') or {}).get('acceptProxyProtocol') is True})
        try:
            route = http_route(r)
        except ValueError:
            route = None
            notes.append(f"Inbound ID {r['id']}: неподходящий HTTP path; проверь маршрут вручную")
        if route: web_routes.append(route)
        if not snis and route is None:
            notes.append(f"Inbound ID {r['id']} ({r['protocol']}:{r['port']}) сохранён без маршрута через HTTPS 443")
    # Routes with ambiguous names are skipped, not silently misdirected.
    from collections import defaultdict
    by_sni=defaultdict(list)
    for item in stream_candidates:
        by_sni[item['sni']].append(item)
    stream=[]
    for name, items in by_sni.items():
        if (public and name==public.lower()) or len({i['id'] for i in items})>1:
            notes.append(f"SNI {name}: конфликт маршрутов; не добавлен в Nginx")
        else: stream.append(items[0])
    # Colliding HTTP path names may not be safely routed; skip those paths.
    # Prefix service names of gRPC must not consume panel/subscription URLs.
    reserved=[web_path]+sub_paths
    unique=[]
    for route in web_routes:
        p=route['path']; conflicts=[r for r in web_routes if r['path']==p]
        if len(conflicts)>1 or any(p==x or p.startswith(x.rstrip('/')+'/') or x.startswith(p.rstrip('/')+'/') for x in reserved):
            notes.append(f"HTTP-маршрут {p}: пересечение путей; сохранён без правила Nginx")
            continue
        unique.append(route)
    # The panel and subscription routes must not overlap each other.
    for i,a in enumerate(reserved):
        for b in reserved[i+1:]:
            if a==b or a.startswith(b.rstrip('/')+'/') or b.startswith(a.rstrip('/')+'/'):
                raise ValueError('Пересекаются пути панели и подписок. Исправь их в панели.')
    next_port = (x for x in range(14000,16000) if x not in used_ports)
    for route in stream:
        if route['proxy']:
            p=next(next_port)
            route['relay']=p
            used_ports.add(p)
        else: route['relay']=None
    return {
       'web_port':web_port, 'web_path':web_path,
       'sub_port':sub_port,'sub_paths':sub_paths,'http_port':http_port,
       'clients':c.execute('SELECT count(*) FROM clients').fetchone()[0] if has_table(c,'clients') else 0,
       'udp_ports': sorted({r['port'] for r in rows if r['enabled'] and r['protocol'] in UDP_ONLY and r['listen'] not in ('127.0.0.1','::1')}),
       'inbounds':len(rows),'enabled':sum(x['enabled'] for x in rows),
       'sni_routes':stream, 'http_routes':unique, 'notes':list(dict.fromkeys(notes)),
    }


def update_hosts(c, old, public, routes):
    if not has_table(c,'hosts'): return
    cols=columns(c,'hosts')
    if not {'inbound_id','address','port'}.issubset(cols): return
    proxy_ids={x['id'] for x in routes['sni_routes']} | {x['id'] for x in routes['http_routes']}
    snis={x['id']:x['sni'] for x in routes['sni_routes']}
    route_tls={x['id'] for x in routes['http_routes']}
    for r in c.execute('SELECT id,inbound_id,address,port FROM hosts').fetchall():
        addr=(r['address'] or '').strip()
        # Don't hijack manually-entered unrelated destinations.
        if addr not in ((old or ''), '', public): continue
        updates={'address':public}
        if r['inbound_id'] in proxy_ids:
            updates['port']=443
            if r['inbound_id'] in route_tls and 'security' in cols:
                updates['security']='tls'
            if r['inbound_id'] in snis and 'sni' in cols and not addr:
                updates['sni']=snis[r['inbound_id']]
        if 'updated_at' in cols: updates['updated_at']=int(time.time()*1000)
        assign=', '.join(f'{k}=?' for k in updates)
        c.execute(f'UPDATE hosts SET {assign} WHERE id=?', [*updates.values(),r['id']])
    # Add missing default hosts for routed inbounds (optional schema).
    for inbound_id in proxy_ids:
        if c.execute('SELECT 1 FROM hosts WHERE inbound_id=?', (inbound_id,)).fetchone(): continue
        values={'inbound_id':inbound_id,'address':public,'port':443}
        if 'remark' in cols: values['remark']='HTTPS 443'
        if 'group_id' in cols: values['group_id']=secrets.token_hex(8)
        if 'sni' in cols and inbound_id in snis: values['sni']=snis[inbound_id]
        if 'security' in cols: values['security']='tls' if inbound_id in route_tls else 'same'
        if 'created_at' in cols: values['created_at']=int(time.time()*1000)
        if 'updated_at' in cols: values['updated_at']=int(time.time()*1000)
        columns_insert=','.join(values)
        placeholders=','.join('?' for _ in values)
        c.execute(f'INSERT INTO hosts ({columns_insert}) VALUES ({placeholders})',list(values.values()))


def prepare(source, out, domain, cert, key, old_host=None, disable_tuic=False):
    src = pathlib.Path(source).resolve(); dst=pathlib.Path(out).resolve()
    if src==dst or dst.exists(): raise ValueError('Нельзя перезаписать исходную или существующую базу')
    with conn_open(src) as c, sqlite3.connect(dst) as backup:
        c.backup(backup)
    try:
        with conn_open(dst, readonly=False) as c:
            with c:
                sc=settings(c)
                original_host=old_host or source_address(sc)
                for key_name,value in {
                    'webListen':'127.0.0.1', 'subListen':'127.0.0.1',
                    'webCertFile':cert,'webKeyFile':key,
                    'subCertFile':cert,'subKeyFile':key,
                    'webDomain':domain,'subDomain':domain,
                }.items():
                    set_setting(c,key_name,value)
                for field,path_field in [('subURI','subPath'),('subJsonURI','subJsonPath'),('subClashURI','subClashPath')]:
                    if sc.get(path_field):
                        set_setting(c,field,f'https://{domain}{check_path(sc[path_field],path_field)}')
                fields=columns(c,'inbounds')
                for r in row_data(c):
                    s=r['stream']; d=r['config']; changed_s=False;changed_d=False
                    tls=s.get('tlsSettings')
                    if isinstance(tls,dict):
                        for certificate in tls.get('certificates',[]) or []:
                            if isinstance(certificate,dict):
                                certificate['certificateFile']=cert
                                certificate['keyFile']=key
                                changed_s=True
                        if tls.get('serverName') == original_host:
                            tls['serverName']=domain;changed_s=True
                    # TUIC versions use server certificates inside settings.
                    srv=d.get('server')
                    if r['protocol']=='tuic' and isinstance(srv,dict):
                        if 'certificate' in srv: srv['certificate']=cert;changed_d=True
                        if 'private_key' in srv: srv['private_key']=key;changed_d=True
                        if original_host and srv.get('sni')==original_host:
                            srv['sni']=domain;changed_d=True
                    # Keep REALITY SNI/target/keys as configured by the user.
                    for entry in s.get('externalProxy',[]) or []:
                        if isinstance(entry,dict) and original_host and entry.get('dest')==original_host:
                            entry['dest']=domain;changed_s=True
                    if disable_tuic and r['protocol']=='tuic' and 'enable' in fields:
                        c.execute('UPDATE inbounds SET enable=0 WHERE id=?',(r['id'],))
                    if changed_s and 'stream_settings' in fields:
                        c.execute('UPDATE inbounds SET stream_settings=? WHERE id=?',
                                  (json.dumps(s,ensure_ascii=False,separators=(',',':')),r['id']))
                    if changed_d:
                        c.execute('UPDATE inbounds SET settings=? WHERE id=?',
                                  (json.dumps(d,ensure_ascii=False,separators=(',',':')),r['id']))
                routeinfo=describe(c, domain)
                update_hosts(c,original_host,domain,routeinfo)
            if c.execute('PRAGMA integrity_check').fetchone()[0]!='ok':
                raise ValueError('Нарушена целостность подготовленной копии')
    except Exception:
        dst.unlink(missing_ok=True)
        raise


def nginx(c, domain, cert, key, http_out, stream_out):
    d=describe(c,domain)
    stream_map=['# Generated from actual enabled inbounds, without hardcoded role names or versions.',
      'stream {','    map $ssl_preread_server_name $vpn_3x_upstream {']
    stream_servers=[]
    for r in d['sni_routes']:
        target = r['relay'] or r['port']
        stream_map.append(f"        {r['sni']} 127.0.0.1:{target};")
        if r['relay']:
            stream_servers.extend([
             '    server {',f"        listen 127.0.0.1:{r['relay']};",
             f"        proxy_pass 127.0.0.1:{r['port']};",'        proxy_protocol on;', '    }'])
    stream_map += [f"        default 127.0.0.1:{d['http_port']};",'    }',
     '    server {','        listen 443;','        listen [::]:443;',
     '        ssl_preread on;','        proxy_pass $vpn_3x_upstream;',
     '        proxy_connect_timeout 10s;','        proxy_timeout 1h;',
     '    }',*stream_servers,'}']
    root=f'''# Generated from real 3x-ui settings; public TLS termination.
map $http_upgrade $connection_upgrade {{ default upgrade; '' close; }}
server {{
    listen 127.0.0.1:{d['http_port']} ssl http2;
    server_name {domain};
    ssl_certificate {cert};
    ssl_certificate_key {key};
    ssl_protocols TLSv1.2 TLSv1.3;
    client_max_body_size 16m;
    error_page 404 /404.html;
    location = /404.html {{ internal; root /var/www/3x-ui-landing; }}
'''
    for route in d['http_routes']:
        p=route['path']; dest=route['upstream']; tls=route['tls']; kind=route['kind']
        if kind=='grpc':
            scheme='grpcs' if tls else 'grpc'
            root+=f'''    location ^~ {p}/ {{
        grpc_pass {scheme}://127.0.0.1:{dest};
        grpc_set_header Host $host;
        grpc_read_timeout 1h;
    }}
'''
        else:
            scheme='https' if tls else 'http'
            matcher=f'= {p}' if kind=='ws' else f'^~ {p}'
            root+=f'''    location {matcher} {{
        proxy_pass {scheme}://127.0.0.1:{dest};
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-Proto https;
'''
            if kind=='ws':
                root+='        proxy_set_header Upgrade $http_upgrade;\n        proxy_set_header Connection $connection_upgrade;\n'
            if tls: root+='        proxy_ssl_verify off; # loopback upstream only\n'
            root+='    }\n'
    root+=f'''    location ^~ {d['web_path']} {{
        proxy_pass https://127.0.0.1:{d['web_port']};
        proxy_ssl_verify off; # loopback upstream only
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Real-IP $remote_addr;
    }}
'''
    if d['sub_port']:
        for p in d['sub_paths']:
            root+=f'''    location ^~ {p} {{
        proxy_pass https://127.0.0.1:{d['sub_port']};
        proxy_ssl_verify off; # loopback upstream only
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-Proto https;
    }}
'''
    root+='''    location = / { root /var/www/3x-ui-landing; try_files /index.html =404; }
    location = /index.html { root /var/www/3x-ui-landing; try_files /index.html =404; }
    location / { return 404; }
}
'''
    pathlib.Path(http_out).write_text(root,encoding='utf-8')
    pathlib.Path(stream_out).write_text('\n'.join(stream_map)+'\n',encoding='utf-8')
    return d


def main():
    ap=argparse.ArgumentParser(description='Data-driven 3x-ui database preparer / Nginx generator')
    ap.add_argument('mode',choices=['inspect','prepare','nginx'])
    ap.add_argument('--db',required=True)
    ap.add_argument('--domain');ap.add_argument('--cert');ap.add_argument('--key')
    ap.add_argument('--out');ap.add_argument('--old-host')
    ap.add_argument('--disable-tuic',action='store_true')
    ap.add_argument('--http-out');ap.add_argument('--stream-out')
    args=ap.parse_args()
    c=conn_open(args.db)
    try:
        if args.mode=='inspect':
            d=describe(c)
            print(json.dumps(d,ensure_ascii=False,indent=2))
            return
    finally:c.close()
    if not all([args.domain,args.cert,args.key]):ap.error('Нужны --domain, --cert, --key')
    host=public_host(args.domain)
    if any(not CERT_RE.fullmatch(x) or '..' in x for x in (args.cert,args.key)):
        ap.error('Сертификат и ключ должны иметь абсолютные безопасные пути')
    if args.mode=='prepare':
        if not args.out:ap.error('Нужен --out')
        prepare(args.db,args.out,host,args.cert,args.key,args.old_host,args.disable_tuic)
        print('Копия базы подготовлена; оригинал не изменён.')
        if args.disable_tuic: print('TUIC временно выключен в копии; записи клиентов сохранены.')
    else:
        if not args.http_out or not args.stream_out:ap.error('Нужны --http-out и --stream-out')
        with conn_open(args.db) as c:
            d=nginx(c,host,args.cert,args.key,args.http_out,args.stream_out)
            for note in d['notes']:print('ПРЕДУПРЕЖДЕНИЕ:',note,file=sys.stderr)
            print(f"Nginx config generated for {d['enabled']} enabled / {d['inbounds']} total inbounds.")

if __name__=='__main__':
    try:main()
    except (ValueError,sqlite3.Error,TypeError,KeyError,OSError) as exc:
        print('ОШИБКА:',str(exc),file=sys.stderr)
        sys.exit(1)
