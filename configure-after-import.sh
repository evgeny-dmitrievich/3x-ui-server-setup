#!/usr/bin/env bash
# PROJECT_VERSION=2.8.1
set -Eeuo pipefail
exec /usr/local/sbin/3x-ui-stack-manager after-import "$@"
