#!/usr/bin/env bash
# Converte artigos de qualquer URL para Markdown ou RTF.
# Thin wrapper: runs convert-url-to-md.py with the interpreter from the shared
# virtualenv in lib/python/.venv, so no activation step is needed.
set -euo pipefail

# Resolve this script's own directory, following symlinks.
SOURCE="${BASH_SOURCE[0]}"
while [ -L "$SOURCE" ]; do
    DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
    SOURCE="$(readlink "$SOURCE")"
    [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE"
done
SCRIPT_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"

PY_DIR="$SCRIPT_DIR/lib/python"
VENV_PY="$PY_DIR/.venv/bin/python"

if [ ! -x "$VENV_PY" ]; then
    echo "Erro: virtualenv nao encontrado em $PY_DIR/.venv" >&2
    echo "Recrie com: uv venv $PY_DIR/.venv --python 3.12 && \\" >&2
    echo "            uv pip install --python $PY_DIR/.venv/bin/python -r $PY_DIR/requirements.txt" >&2
    exit 1
fi

exec "$VENV_PY" "$PY_DIR/convert-url-to-md.py" "$@"
