#!/usr/bin/env bash
# Creates (or recreates) the shared Python virtualenv used by the wrappers.
# Run once after cloning this repo.
set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY_DIR="$SCRIPT_DIR/lib/python"

if ! command -v uv >/dev/null; then
    echo "Erro: 'uv' nao encontrado. Instale com: brew install uv" >&2
    exit 1
fi

echo "==> Criando virtualenv em $PY_DIR/.venv"
uv venv "$PY_DIR/.venv" --python 3.12

echo "==> Instalando dependencias"
uv pip install --python "$PY_DIR/.venv/bin/python" -r "$PY_DIR/requirements.txt"

echo "==> Tornando os scripts executaveis"
chmod +x "$SCRIPT_DIR"/*.sh

echo
echo "Pronto. Adicione ao PATH no seu ~/.zshrc:"
echo "  export PATH=\"$SCRIPT_DIR:\$PATH\""
