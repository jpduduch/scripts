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

# shellcheck source=lib/preflight.sh
. "$SCRIPT_DIR/lib/preflight.sh"

# pandoc is only needed for RTF output, so only require it when -rtf is asked for.
EXTRA_TOOLS=""
for _arg in "$@"; do
    if [ "$_arg" = "-rtf" ]; then EXTRA_TOOLS="pandoc"; fi
done
preflight $EXTRA_TOOLS || exit 1

exec "$PY_DIR/.venv/bin/python" "$PY_DIR/convert-url-to-md.py" "$@"
