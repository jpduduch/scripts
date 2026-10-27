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

# Only written once everything above succeeded; preflight treats a venv without
# it as an interrupted or failed install.
touch "$PY_DIR/.venv/.bootstrap-complete"

echo "==> Tornando os scripts executaveis"
chmod +x "$SCRIPT_DIR"/*.sh

echo "==> Adicionando $SCRIPT_DIR ao PATH"

# Follows a chain of symlinks (relative or absolute) to the real file, so the
# line lands in e.g. a dotfiles repo instead of replacing the link.
resolve_link() {
    local f="$1" dir
    while [ -L "$f" ]; do
        dir="$(cd -P "$(dirname "$f")" && pwd)"
        f="$(readlink "$f")"
        case "$f" in /*) ;; *) f="$dir/$f" ;; esac
    done
    printf '%s\n' "$f"
}

# The user's login shell, not the bash running this script.
case "$(basename "${SHELL:-}")" in
    zsh)  RC="${ZDOTDIR:-$HOME}/.zshrc" ;;
    bash) if _pf_is_mac; then RC="$HOME/.bash_profile"; else RC="$HOME/.bashrc"; fi ;;
    *)    RC="" ;;
esac

# Written as $HOME/... when possible, so a dotfiles repo shared between macOS
# and Linux works on both. Compared physically: on Fedora Atomic /home is a
# symlink to /var/home.
HOME_REAL="$(cd -P "$HOME" && pwd)"
case "$SCRIPT_DIR" in
    "$HOME_REAL"/*) REL="${SCRIPT_DIR#"$HOME_REAL"/}"; ENTRY='$HOME/'"$REL" ;;
    *)              REL=""; ENTRY="$SCRIPT_DIR" ;;
esac
EXPORT_LINE="export PATH=\"$ENTRY:\$PATH\""

# True if an uncommented line already references this folder, in any of the
# usual spellings.
already_on_path() {
    local lines
    lines="$(grep -v '^[[:space:]]*#' "$1" || true)"
    printf '%s\n' "$lines" | grep -qF -e "$SCRIPT_DIR" && return 0
    [ -n "$REL" ] && printf '%s\n' "$lines" | grep -qF \
        -e "$HOME/$REL" -e "\$HOME/$REL" -e "\${HOME}/$REL" -e "~/$REL"
}

manual_path() {
    echo "    $1. Adicione manualmente ao arquivo de configuracao do seu shell:"
    echo "      $EXPORT_LINE"
}

if [ -z "$RC" ]; then
    manual_path "Shell '${SHELL:-desconhecido}' nao suportado"
else
    TARGET="$(resolve_link "$RC")"
    if [ -L "$RC" ] && [ ! -e "$TARGET" ]; then
        manual_path "$RC aponta para $TARGET, que nao existe"
    elif [ -e "$TARGET" ] && [ ! -w "$TARGET" ]; then
        manual_path "Sem permissao de escrita em $TARGET"
    elif [ -f "$TARGET" ] && already_on_path "$TARGET"; then
        echo "    Ja configurado em $TARGET"
    else
        if [ "$TARGET" != "$RC" ]; then
            echo "    $RC aponta para $TARGET; adicionando la"
        fi
        {
            # Keep the previous last line intact if the file lacks a final newline.
            if [ -s "$TARGET" ]; then
                if [ -n "$(tail -c1 "$TARGET")" ]; then echo; fi
                echo
            fi
            echo "# Scripts pessoais (adicionado por bootstrap.sh)"
            echo "$EXPORT_LINE"
        } >> "$TARGET"
        echo "    Adicionado em $TARGET"
        echo "    Abra um novo terminal (ou rode: source $RC) para usar."
    fi
fi

echo
echo "Pronto."
