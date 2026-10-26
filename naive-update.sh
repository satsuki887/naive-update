#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if ! command -v python3 >/dev/null 2>&1; then
    echo '需要 Python 3.9+。请通过系统官方软件源安装 python3。' >&2
    exit 1
fi
exec python3 "$SCRIPT_DIR/naive_update.py" "$@"
