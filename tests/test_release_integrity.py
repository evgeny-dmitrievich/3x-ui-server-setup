#!/usr/bin/env python3
"""Source-layout, syntax and absence of brittle version/inbound assumptions."""
import ast
import subprocess
from pathlib import Path

root=Path(__file__).resolve().parents[1]
scripts=['setup.sh','prepare-import.sh',
         'configure-after-import.sh','change-domain.sh','stack-manager.sh','update-import-tools.sh',
         'landing/install.sh','wireguard/setup.sh','wireguard/manage.sh']
for name in scripts:
    assert (root/name).is_file(), name
    subprocess.run(['bash','-n',str(root/name)],check=True)
for name in ['db_tool.py']:
    ast.parse((root/name).read_text())
for name in ['test_dynamic_inbounds.py','test_bootstrap.py','test_healthcheck_mock.py','test_pre_import.py']:
    ast.parse((root/'tests'/name).read_text())
for name in ['landing/index.html','landing/404.html','.gitignore','README.md']:
    assert (root/name).is_file(), name
setup=(root/'setup.sh').read_text()
manager=(root/'stack-manager.sh').read_text()
pre=(root/'prepare-import.sh').read_text()
db=(root/'db_tool.py').read_text()
assert 'INBOUND_SPECS' not in db
assert 'migrate_vpn_reality' not in db
assert 'REALITY_SNI =' not in db
assert 'PROJECT_VERSION=${PROJECT_VERSION}' not in setup
assert 'grep -Fqx "# PROJECT_VERSION=${PROJECT_VERSION}"' not in manager
assert 'grep -Fqx' not in pre
assert 'python3 "$DB_TOOL" inspect --db "$LIVE_DB"' in manager
assert 'healthcheck "$LIVE_DB" "$TARGET_HOST"' in manager
assert 'snapshot_configs' in manager and 'restore_configs' in manager
assert 'live-before.db' in manager
assert 'proxy_ssl_verify off;' in db and 'proxy_ssl_verify on;' not in db
assert 'proxy_set_header Upgrade $http_upgrade;' in db
assert 'proxy_set_header Connection $connection_upgrade;' in db
assert 'webBasePath' in db and 'webPort' in db
assert 'ssl_preread on;' in db
assert 'get_snis' in db and 'http_route' in db and 'udp_ports' in db
assert '3x-ui-after-import' in setup
assert '3x-ui-prepare-import' in setup
assert '3x-ui-change-domain' in setup
assert 'x-ui setting -username' not in manager
assert 'SSH_PORT=1335' in setup
assert 'PORT=51820' in (root/'wireguard/setup.sh').read_text()
print('PASS: install bundle, dynamic routing, no version gate, rollback, HTTPS, SSH and WireGuard.')

for deprecated in ('resume-after-fail2ban.sh','reality-443.sh','test_db_tool.py'):
    assert not (root/deprecated).exists(), f'Deprecated file remains: {deprecated}'
assert 'resume-after-fail2ban.sh' not in (root/'landing/install.sh').read_text()
