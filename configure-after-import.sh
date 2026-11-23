#!/usr/bin/env bash
set -Eeuo pipefail
exec /usr/local/sbin/3x-ui-stack-manager after-import "$@"
