#!/usr/bin/env python3
"""Offline release checks before uploading the bundle to GitHub."""
from pathlib import Path
import subprocess
import ast
root=Path(__file__).resolve().parent
version='2.6.0'
files=[
'setup.sh','reality-443.sh','prepare-import.sh','configure-after-import.sh','change-domain.sh','stack-manager.sh',
'db_tool.py','landing/install.sh','landing/index.html','landing/404.html',
'wireguard/setup.sh','wireguard/manage.sh','resume-after-fail2ban.sh',
]
for name in files:
    p=root/name
    assert p.is_file() and p.stat().st_size, f'missing: {name}'
    assert f'PROJECT_VERSION={version}' in p.read_text(), f'wrong version: {name}'
    if p.suffix=='.sh':
        subprocess.run(['bash','-n',str(p)],check=True)
    if p.suffix=='.py':
        ast.parse(p.read_text())
setup=(root/'setup.sh').read_text()
manager=(root/'stack-manager.sh').read_text()
db=(root/'db_tool.py').read_text()
assert setup.index("PHASE='Проверка комплекта исходных файлов'") < setup.index("PHASE='Preparing console font'")
assert 'cmp -s -- "$0" "${SOURCE_STAGE}/setup.sh"' in setup
assert 'PROJECT_VERSION=${PROJECT_VERSION}' in setup
assert 'cp -a "${SOURCE_STAGE}/landing/install.sh"' in setup
assert '"file://${SOURCE_STAGE}"' in setup
assert 'for ((attempt=0; attempt<12; attempt++))' in setup
assert 'grep -Fqx "# PROJECT_VERSION=${PROJECT_VERSION}" "$DB_TOOL"' in manager
assert 'proxy_ssl_verify on;' not in db
assert 'proxy_ssl_verify off;' in db
assert 'Локальная панель не ответила' in manager
assert 'snapshot_configs' in manager and 'restore_configs' in manager
assert 'webBasePath' in db and 'webPort' in db
assert 'Сайт-заглушка' in manager or 'сайт-заглушка' in manager
resume=(root/'resume-after-fail2ban.sh').read_text()
assert 'cp -a "${SOURCE_STAGE}/landing/install.sh"' in resume
assert 'cmp -s -- "$0" "${SOURCE_STAGE}/resume-after-fail2ban.sh"' in resume
assert 'sudo 3x-ui-after-import' in setup
assert 'prepare-import.sh /usr/local/sbin/3x-ui-prepare-import' in setup
assert 'prepare-import.sh' in setup
assert 'INBOUND_SPECS' in db and 'Не хватает подключений из нашей объединённой базы' not in db
assert 'disable_tuic' in db
print('PASS: file bundle, syntax, version checks, console, Fail2ban, Nginx and rollback guards')
