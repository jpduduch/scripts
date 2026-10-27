#!/usr/bin/env bash
# Creates (or recreates) the shared Python virtualenv used by the wrappers.
# Run once after cloning this repo.
#
# Installs from lib/python/requirements.lock: exact versions, verified by
# hash, so a rebuild always reproduces the set that was actually tested.
set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY_DIR="$SCRIPT_DIR/lib/python"
LOCK="$PY_DIR/requirements.lock"
PY_VERSION="3.12"

# For _pf_hint: the install command for the running OS.
. "$SCRIPT_DIR/lib/preflight.sh"

if ! command -v uv >/dev/null; then
    echo "Erro: 'uv' nao encontrado. Instale com: $(_pf_hint uv)" >&2
    exit 1
fi

if [ ! -f "$LOCK" ]; then
    echo "Erro: lockfile nao encontrado em $LOCK" >&2
    exit 1
fi

echo "==> Criando virtualenv (Python $PY_VERSION) em $PY_DIR/.venv"
# uv refuses to overwrite an existing venv, which broke re-runs after a failed
# install and folders copied over with a venv from another OS. rm -rf instead
# of --clear so older distro-packaged uv versions work too.
rm -rf "$PY_DIR/.venv"
uv venv "$PY_DIR/.venv" --python "$PY_VERSION"

echo "==> Instalando dependencias travadas de requirements.lock"
uv pip install --python "$PY_DIR/.venv/bin/python" --require-hashes -r "$LOCK"

echo "==> Tornando os scripts executaveis"
chmod +x "$SCRIPT_DIR"/*.sh

echo
echo "Pronto. Adicione ao PATH no seu ~/.zshrc (ou ~/.bashrc no Linux):"
echo "  export PATH=\"$SCRIPT_DIR:\$PATH\""
