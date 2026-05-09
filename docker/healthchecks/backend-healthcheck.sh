#!/usr/bin/env bash
set -Eeuo pipefail

python - <<'PY'
import os
import socket
import sys
import urllib.request

url = os.environ.get("BACKEND_HEALTHCHECK_URL", "http://127.0.0.1:8000/admin/login/")
try:
    with urllib.request.urlopen(url, timeout=3) as response:
        if response.status >= 500:
            sys.exit(1)
except Exception:
    sys.exit(1)

try:
    socket.create_connection(("redis", 6379), timeout=2).close()
except OSError:
    sys.exit(1)
PY
