#!/usr/bin/env python3
"""Test healthcheck readiness retry without Nginx or a live server."""
from pathlib import Path
import subprocess, tempfile
root=Path(__file__).parent
source=(root/'stack-manager.sh').read_text()
start=source.index('healthcheck() {')
end=source.index('\napply_stack() {',start)
func=source[start:end]
script=r'''#!/usr/bin/env bash
set -u
CURRENT_STEP=''
DB_TOOL='__DBTOOL__'
COUNT_FILE='__COUNTFILE__'
warn() { printf 'WARN: %s\n' "$*" >&2; }
say() { printf 'SUCCESS: %s\n' "$*"; }
curl() {
  local args="$*" n
  case "$args" in
    *'https://127.0.0.1:'*)
      n=$(cat "$COUNT_FILE")
      n=$((n+1))
      printf '%s' "$n" > "$COUNT_FILE"
      if (( n <= 2 )); then return 7; fi
      printf '302'
      ;;
    *'__missing_nature_page_3xui__'*) printf '404';;
    *'https://45.38.23.129/'*) printf '200';;
    *) printf '200';;
  esac
}
__FUNCTION__
healthcheck '__DB__' '45.38.23.129'
'''
with tempfile.TemporaryDirectory() as t:
    countfile=Path(t)/'cnt'
    countfile.write_text('0')
    script=(script.replace('__DBTOOL__',str(root/'db_tool.py'))
                  .replace('__COUNTFILE__',str(countfile))
                  .replace('__FUNCTION__',func)
                  .replace('__DB__','__DB_ARG__'))
    p=Path(t)/'test.sh'
    p.write_text(script)
    import sys
    if len(sys.argv)!=2:
        raise SystemExit('usage: test_healthcheck_mock.py /path/to/private.db')
    p.write_text(p.read_text().replace('__DB_ARG__',sys.argv[1]))
    r=subprocess.run(['bash',str(p)],capture_output=True,text=True,timeout=20)
    assert r.returncode==0,(r.stdout,r.stderr)
    assert 'SUCCESS: Панель отвечает' in r.stdout,(r.stdout,r.stderr)
    assert countfile.read_text()=='3',countfile.read_text()
print('PASS: healthcheck retries delayed panel startup, validates Nginx + 200/404.')
