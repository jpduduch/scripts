#!/usr/bin/env bash
# Baixa as fontes usadas por uma ou mais paginas web.
# Thin wrapper: runs fetch-fonts.py with the interpreter from the shared
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

# shellcheck source=lib/preflight.sh
. "$SCRIPT_DIR/lib/preflight.sh"

EXTRA_TOOLS=""
preflight $EXTRA_TOOLS || exit 1

exec "$PY_DIR/.venv/bin/python" "$PY_DIR/fetch-fonts.py" "$@"
