#!/usr/bin/env bash
# Downloads a subtitle for a movie and syncs it to the movie's audio.
# Thin wrapper: runs fetch-subtitle.py with the interpreter from the shared
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

# ffprobe inspects the movie; ffsubsync uses ffmpeg to extract its audio.
preflight ffmpeg ffprobe || exit 1

exec "$PY_DIR/.venv/bin/python" "$PY_DIR/fetch-subtitle.py" "$@"
