#!/usr/bin/env bash
set -euo pipefail

echo "[preflight] bash"
bash --version | sed -n '1p'

echo "[preflight] tar --exclude"
if ! tar --help 2>&1 | grep -q -- "--exclude"; then
  echo "tar does not support --exclude, or it is not visible in tar --help output." >&2
  exit 1
fi

echo "[preflight] docker version"
docker version

echo "[preflight] docker daemon"
docker info >/dev/null

echo "[preflight] ok"
