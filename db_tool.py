#!/usr/bin/env python3
# PROJECT_VERSION=2.5.0
"""Private SQLite migration + nginx generation for the specific 3x-ui database.
This program never prints passwords, keys, client UUIDs or tokens.
"""
import argparse
import ipaddress
import json
import pathlib
import re
import sqlite3
import sys
import secrets
import time

NAME = re.compile(r"^[a-zA-Z0-9.-]+$")
PATH = re.compile(r"^/[a-zA-Z0-9_./-]*$")


def validate_domain(text):
    """Accept owned DNS domains OR public IPv4 used for Let's Encrypt IP SSL."""
    try:
        addr = ipaddress.ip_address(text)
    except ValueError:
        if not NAME.fullmatch(text) or "." not in text or ".." in text or len(text) > 253:
            raise ValueError("Некорректный домен")
        return text.lower()
    if addr.version != 4 or not addr.is_global:
        raise ValueError("Для IP SSL нужен публичный IPv4")
    return str(addr)


def connect(path, readonly=True):
    if not pathlib.Path(path).is_file():
        raise ValueError(f"База не найдена: {path}")
    conn = sqlite3.connect(f"file:{pathlib.Path(path).resolve()}?mode={'ro' if readonly else 'rw'}", uri=True)
    conn.row_factory = sqlite3.Row
    if conn.execute("PRAGMA integrity_check").fetchone()[0] != "ok":
        raise ValueError("SQLite integrity_check не прошла")
    required = {"inbounds", "settings", "hosts", "clients"}
    present = {r[0] for r in conn.execute("SELECT name FROM sqlite_master WHERE type='table'")}
    if not required <= present:
        raise ValueError("База не соответствует схеме 3x-ui")
    return conn


def cfg(c):
    return {r["key"]: r["value"] for r in c.execute("SELECT key,value FROM settings")}


def setting(c, name, value):
    if c.execute("SELECT count(*) FROM settings WHERE key=?", (name,)).fetchone()[0]:
        c.execute("UPDATE settings SET value=? WHERE key=?", (str(value), name))
    else:
        c.execute("INSERT INTO settings(key,value) VALUES(?,?)", (name, str(value)))


def inbound(c, remark):
    rows = list(c.execute("SELECT * FROM inbounds WHERE remark=?", (remark,)))
    if len(rows) != 1:
        raise ValueError(f"Ожидалось ровно одно подключение '{remark}', найдено {len(rows)}")
    return rows[0]


def stream(c, remark):
    return json.loads(inbound(c, remark)["stream_settings"] or "{}")


def path(s):
    if not PATH.fullmatch(s) or ".." in s or "//" in s:
        raise ValueError("Недопустимый путь из базы (возможно, другая схема)")
    return s


def sni(s):
    if not NAME.fullmatch(s) or "." not in s:
        raise ValueError("Недопустимый SNI из базы")
    return s


def describe(c):
    sc = cfg(c)
    needed = ("webBasePath", "subPath", "subJsonPath", "subClashPath", "webPort", "subPort")
    for k in needed:
        if not sc.get(k):
            raise ValueError(f"Отсутствует настройка {k}")
    by_name = {r["remark"] for r in c.execute("SELECT remark FROM inbounds")}
    expected = {"VPN", "XHTTP", "VLESS-WS", "VMess-WS", "Trojan-gRPC", "MTProto"}
    if not expected <= by_name:
        raise ValueError("Не хватает подключений из нашей объединённой базы")
    x = stream(c, "XHTTP")
    v = stream(c, "VPN")
    mt = json.loads(inbound(c, "MTProto")["settings"] or "{}")
    if x.get("sockopt", {}).get("acceptProxyProtocol") is not True:
        raise ValueError("XHTTP не ожидает PROXY protocol; сценарий nginx требует проверки")
    if mt.get("proxyProtocolListener") is not True:
        raise ValueError("MTProto не ожидает PROXY protocol; сценарий nginx требует проверки")
    result = {
        "web_port": int(sc["webPort"]),
        "sub_port": int(sc["subPort"]),
        "web_path": path(sc["webBasePath"]),
        "sub_paths": [path(sc[z]) for z in ("subPath", "subJsonPath", "subClashPath")],
        "vless_sni": sni(v["realitySettings"]["serverNames"][0]),
        "xhttp_sni": sni(x["realitySettings"]["serverNames"][0]),
        "mtproto_sni": sni(mt["fakeTlsDomain"]),
        "ws_vless": path(stream(c, "VLESS-WS")["wsSettings"]["path"]),
        "ws_vmess": path(stream(c, "VMess-WS")["wsSettings"]["path"]),
        "grpc_service": path("/" + stream(c, "Trojan-gRPC")["grpcSettings"]["serviceName"]).lstrip("/"),
        "ports": [],
        "clients": c.execute("SELECT count(*) FROM clients").fetchone()[0],
        "inbounds": c.execute("SELECT count(*) FROM inbounds").fetchone()[0],
    }
    if len(set([result['vless_sni'], result['xhttp_sni'], result['mtproto_sni']])) != 3:
        raise ValueError("Пересечение SNI: нельзя автоматически собрать stream-маршруты")
    for r in c.execute("SELECT port,protocol,listen,enable,remark FROM inbounds"):
        if not r["enable"]:
            continue
        prot = r["protocol"]
        method = "udp" if prot in {"hysteria", "tuic", "amneziawg", "wireguard"} else "tcp"
        result["ports"].append({"port": r["port"], "protocol": method, "listen": r["listen"], "remark": r["remark"]})
    for key in ('web_port','sub_port'):
        if not 1024 <= result[key] <= 65535:
            raise ValueError(f"Некорректный {key}")
    for field in ['ws_vless','ws_vmess','web_path',*result['sub_paths']]:
        if field == '/':
            raise ValueError("Отказ: открытый корневой path вместо отдельного пути")
    return result



REALITY_SNI = "dl.google.com"
OLD_REALITY_SNI = "apple.com"


def migrate_vpn_reality(c, public_address):
    """Only our named VPN inbound. Preserves keys, UUIDs, stats and unrelated inbounds."""
    r = inbound(c, "VPN")
    if r["port"] != 13133 or r["protocol"] != "vless":
        raise ValueError("VPN inbound differs from expected VLESS TCP:13133")
    s = json.loads(r["stream_settings"] or "{}")
    if s.get("network") != "tcp" or s.get("security") != "reality":
        raise ValueError("VPN is not TCP Reality")
    if s.get("externalProxy"):
        raise ValueError("VPN contains legacy externalProxy entries; review manually")
    reality = s.get("realitySettings") or {}
    if reality.get("serverNames") not in ([OLD_REALITY_SNI], [REALITY_SNI]):
        raise ValueError("Unexpected VPN Reality serverNames; refusing migration")
    if reality.get("target") not in (f"{OLD_REALITY_SNI}:443", f"{REALITY_SNI}:443"):
        raise ValueError("Unexpected VPN Reality target; refusing migration")
    client_sni = reality.get("settings", {}).get("serverName", "")
    if client_sni not in ("", OLD_REALITY_SNI, REALITY_SNI):
        raise ValueError("Unexpected VPN Reality client serverName")
    reality["serverNames"] = [REALITY_SNI]
    reality["target"] = f"{REALITY_SNI}:443"
    if isinstance(reality.get("settings"), dict):
        reality["settings"]["serverName"] = REALITY_SNI
    s["realitySettings"] = reality
    c.execute("UPDATE inbounds SET stream_settings=?, listen=? WHERE id=?", (
        json.dumps(s, ensure_ascii=False, separators=(",", ":")), "127.0.0.1", r["id"]))
    hosts = c.execute("SELECT id,address,port FROM hosts WHERE inbound_id=?", (r["id"],)).fetchall()
    if len(hosts) > 1:
        raise ValueError("Multiple VPN Hosts found; review before migration")
    if hosts:
        h = hosts[0]
        if h["address"] not in ("", None, public_address):
            raise ValueError("VPN Host has an external custom address; review before migration")
        if h["port"] not in (0, 13133, 443):
            raise ValueError("VPN Host uses unexpected port")
        c.execute("""UPDATE hosts SET address=?,port=443,security='same',sni=?,
          override_sni_from_address=0,keep_sni_blank=0,is_disabled=0,is_hidden=0,
          updated_at=? WHERE id=?""", (public_address, REALITY_SNI, int(time.time()*1000), h["id"]))
    else:
        now = int(time.time() * 1000)
        c.execute("""INSERT INTO hosts
          (group_id,inbound_id,sort_order,remark,is_disabled,is_hidden,address,port,
           security,sni,override_sni_from_address,keep_sni_blank,created_at,updated_at)
          VALUES (?,?,0,?,0,0,?,443,'same',?,0,0,?,?)""",
          (secrets.token_hex(8),r["id"],"VLESS Reality 443",public_address,REALITY_SNI,now,now))

def save_db(c, source, target, domain, cert, key, old_host=None):
    if pathlib.Path(source).resolve() == pathlib.Path(target).resolve():
        raise ValueError("Нельзя изменять оригинал базы")
    if pathlib.Path(target).exists():
        raise ValueError("Выходной файл уже существует, отказ от перезаписи")
    # SQLite can use WAL: a raw file copy may silently omit recent writes.
    # The SQLite backup API captures one consistent database snapshot.
    dst = sqlite3.connect(target)
    try:
        c.backup(dst)
    except Exception:
        dst.close()
        pathlib.Path(target).unlink(missing_ok=True)
        raise
    finally:
        dst.close()
    t = connect(target, readonly=False)
    try:
        with t:
            for k, v in {
                "webListen": "127.0.0.1", "subListen": "127.0.0.1",
                "webCertFile": cert, "webKeyFile": key,
                "subCertFile": cert, "subKeyFile": key,
                "subURI": f"https://{domain}{path(cfg(t)['subPath'])}",
                "subJsonURI": f"https://{domain}{path(cfg(t)['subJsonPath'])}",
                "subClashURI": f"https://{domain}{path(cfg(t)['subClashPath'])}",
                "subDomain": domain,
                "webDomain": domain,
            }.items():
                setting(t,k,v)
            # On initial import, replace hosts from the original server.
            # On later domain changes, replace ONLY the previously managed address.
            if old_host:
                t.execute("UPDATE hosts SET address=? WHERE address=?", (domain, old_host))
            else:
                t.execute("UPDATE hosts SET address=? WHERE address IS NOT NULL AND address != ''", (domain,))
            migrate_vpn_reality(t, domain)
            for r in t.execute("SELECT id,stream_settings,settings,protocol FROM inbounds").fetchall():
                s = json.loads(r["stream_settings"] or "{}")
                d = json.loads(r["settings"] or "{}")
                changed_s = changed_d = False
                for e in s.get("externalProxy", []):
                    if isinstance(e, dict) and e.get("dest"):
                        e["dest"] = domain
                        changed_s = True
                if r['protocol'] == 'hysteria':
                    tl = s.get('tlsSettings', {})
                    tl['serverName'] = domain
                    for e in tl.get('certificates', []):
                        e['certificateFile'] = cert
                        e['keyFile'] = key
                    changed_s = True
                if r['protocol'] == 'tuic' and isinstance(d.get('server'),dict):
                    d['server']['certificate'] = cert
                    d['server']['private_key'] = key
                    d['server']['sni'] = domain
                    changed_d = True
                if changed_s:
                    t.execute("UPDATE inbounds SET stream_settings=? WHERE id=?",(json.dumps(s,ensure_ascii=False,separators=(',',':')),r['id']))
                if changed_d:
                    t.execute("UPDATE inbounds SET settings=? WHERE id=?",(json.dumps(d,ensure_ascii=False,separators=(',',':')),r['id']))
        if t.execute('PRAGMA integrity_check').fetchone()[0] != 'ok':
            raise ValueError('Нарушение целостности результата')
    finally:
        t.close()


def nginx(c, domain, cert, key, http_out, stream_out):
    d = describe(c)
    # Nginx's stream module is loaded at the top level through Ubuntu's modules-enabled.
    stream_conf = f'''# Generated from a PRIVATE 3x-ui DB. Must be included at nginx top level.
stream {{
    map $ssl_preread_server_name $vpn_3x_upstream {{
        {d['xhttp_sni']} 127.0.0.1:10447;
        {d['vless_sni']} 127.0.0.1:13133;
        {d['mtproto_sni']} 127.0.0.1:10448;
        default 127.0.0.1:10446;
    }}
    server {{
        listen 443;
        listen [::]:443;
        ssl_preread on;
        proxy_pass $vpn_3x_upstream;
        proxy_connect_timeout 10s;
        proxy_timeout 1h;
        # Do NOT enable proxy_protocol here: plain REALITY on 13133 cannot read it.
    }}
    server {{
        listen 127.0.0.1:10447;
        proxy_pass 127.0.0.1:10444;
        proxy_protocol on; # XHTTP expects this
    }}
    server {{
        listen 127.0.0.1:10448;
        proxy_pass 127.0.0.1:10445;
        proxy_protocol on; # MTProto expects this
    }}
}}
'''
    ws_one,ws_two = d['ws_vless'],d['ws_vmess']
    http_conf = f'''# Generated from private DB. TLS is terminated on local 10446 after TCP SNI routing.
map $http_upgrade $connection_upgrade {{ default upgrade; '' close; }}
server {{
    listen 127.0.0.1:10446 ssl http2;
    server_name {domain};
    ssl_certificate {cert};
    ssl_certificate_key {key};
    ssl_protocols TLSv1.2 TLSv1.3;
    client_max_body_size 16m;
    error_page 404 /404.html;
    location = /404.html {{
        internal;
        root /var/www/3x-ui-landing;
    }}
    location = {ws_one} {{
        proxy_pass http://127.0.0.1:10451;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_set_header Host $host;
    }}
    location = {ws_two} {{
        proxy_pass http://127.0.0.1:10452;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_set_header Host $host;
    }}
    location ^~ /{d['grpc_service']}/ {{
        grpc_pass grpc://127.0.0.1:10453;
        grpc_set_header Host $host;
        grpc_read_timeout 1h;
    }}
    location ^~ {d['web_path']} {{
        proxy_pass https://127.0.0.1:{d['web_port']};
        # The upstream is the local 3x-ui HTTPS server, bound to loopback only.
        # The public TLS connection is independently verified by the browser.
        proxy_ssl_verify off;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Real-IP $remote_addr;
    }}
'''
    for sub_path in d['sub_paths']:
        http_conf += f'''    location ^~ {sub_path} {{
        proxy_pass https://127.0.0.1:{d['sub_port']};
        # The upstream is the local 3x-ui HTTPS server, bound to loopback only.
        # The public TLS connection is independently verified by the browser.
        proxy_ssl_verify off;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-Proto https;
    }}
'''
    # The ordinary homepage is entirely static. It does not reveal or redirect
    # visitors to the private panel. Admin and subscription paths above win.
    http_conf += '''    location = / {
        root /var/www/3x-ui-landing;
        try_files /index.html =404;
    }
    location = /index.html {
        root /var/www/3x-ui-landing;
        try_files /index.html =404;
    }
    location / { return 404; }
}
'''
    pathlib.Path(http_out).write_text(http_conf)
    pathlib.Path(stream_out).write_text(stream_conf)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('mode', choices=['inspect','prepare','nginx'])
    ap.add_argument('--db', required=True)
    ap.add_argument('--domain')
    ap.add_argument('--cert')
    ap.add_argument('--key')
    ap.add_argument('--out')
    ap.add_argument('--old-host', default=None)
    ap.add_argument('--http-out')
    ap.add_argument('--stream-out')
    args = ap.parse_args()
    c = connect(args.db)
    try:
        d = describe(c)
        if args.mode == 'inspect':
            print(json.dumps(d,ensure_ascii=False,indent=2))
            return
        if not all([args.domain,args.cert,args.key]):
            ap.error('Нужно указать --domain, --cert, --key')
        domain=validate_domain(args.domain)
        for p in (args.cert,args.key):
            if not p.startswith('/') or not re.fullmatch(r'/[A-Za-z0-9_.\-/]+', p):
                raise ValueError('Используй абсолютные пути к сертификатам без пробелов')
        if args.mode=='prepare':
            if not args.out: ap.error('Нужен --out')
            save_db(c,args.db,args.out,domain,args.cert,args.key,args.old_host)
            print('Копия базы подготовлена; источник не изменён.')
        else:
            if not args.http_out or not args.stream_out:
                ap.error('Нужны --http-out и --stream-out')
            nginx(c,domain,args.cert,args.key,args.http_out,args.stream_out)
            print('Nginx config generated.')
    finally:
        c.close()

if __name__=='__main__':
    try:main()
    except (ValueError,sqlite3.Error,KeyError,IndexError,TypeError,FileNotFoundError) as e:
        print(f'ОШИБКА: {e}',file=sys.stderr);sys.exit(1)
