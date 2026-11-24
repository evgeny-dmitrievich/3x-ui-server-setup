#!/usr/bin/env bash
# PROJECT_VERSION=2.5.0
set -Eeuo pipefail
exec /usr/local/sbin/3x-ui-stack-manager change-domain "$@"
