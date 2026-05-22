#!/usr/bin/env bash
set -euo pipefail

echo "[preflight] bash"
bash --version | sed -n '1p'

echo "[preflight] tar --exclude"
if ! tar --help 2>&1 | grep -q -- "--exclude"; then
  echo "tar does not support --exclude, or it is not visible in tar --help output." >&2
  exit 1
fi

ensure_docker_daemon() {
  if docker info >/dev/null 2>&1; then
    return 0
  fi

  echo "[preflight] docker daemon is not ready"
  if [ "$(uname -s 2>/dev/null || echo unknown)" = "Darwin" ] && command -v open >/dev/null 2>&1; then
    echo "[preflight] trying to start Docker Desktop"
    open -gj -a Docker >/dev/null 2>&1 || open -a Docker >/dev/null 2>&1 || true
  fi

  attempt=1
  while [ "$attempt" -le 60 ]; do
    if docker info >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
    attempt=$((attempt + 1))
  done

  echo "Docker daemon did not become ready." >&2
  docker info
}

echo "[preflight] docker version"
docker --version

echo "[preflight] docker daemon"
ensure_docker_daemon

echo "[preflight] docker server"
docker version

echo "[preflight] ok"
