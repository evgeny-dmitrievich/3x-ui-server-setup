"""Offline static checks. Never reconfigure a real server from a test."""
from pathlib import Path
import subprocess

base = Path(__file__).resolve().parent
for filename in ("setup.sh", "configure-after-import.sh"):
    subprocess.run(["bash", "-n", str(base / filename)], check=True)
    subprocess.run(["bash", str(base / filename), "--help"], check=True, stdout=subprocess.DEVNULL)

bootstrap = (base / "setup.sh").read_text()
finish = (base / "configure-after-import.sh").read_text()
assert '--db' not in bootstrap, "bootstrap unexpectedly requires database argument"
assert "XUI_SSL_MODE=\"$SSL_MODE\"" in bootstrap
assert "SSL_MODE=ip" in bootstrap and "SSL_MODE=domain" in bootstrap
assert "-checkip" in bootstrap and "-checkhost" in bootstrap
assert "00-3x-ui-bootstrap.conf" in bootstrap
assert "proxy_pass 127.0.0.1:13350" in bootstrap
assert "ufw allow 1335/tcp" in bootstrap
assert "ufw allow 13133/tcp" in bootstrap
assert "for p in 443 8444 51821 51822" in bootstrap
assert "SSH_PORT=1335" in bootstrap
assert "SSL_STATE_FILE" in finish
assert "00-3x-ui-bootstrap.conf.before" in finish
assert "--installcert" in finish and "systemctl reload nginx" in finish
assert "DB_TOOL" in finish and 'prepare --db' in finish and 'nginx --db' in finish
assert 'live-before-finalize.db' in finish
assert (base / ".gitignore").is_file()
print("OK: 1-command install with domain/IP HTTPS, SSH, backup, after-import compatibility.")
