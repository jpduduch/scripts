# Shared dependency preflight for the Python wrappers.
# Sourced, never executed. Expects SCRIPT_DIR and PY_DIR to be set.
#
# Reports EVERY missing dependency in a single message, in the order they need
# to be resolved, with an install command matched to the running OS.
#
# Deliberately avoids bash arrays: macOS still ships bash 3.2, where an empty
# array under `set -u` is an error.

_pf_is_mac() { [ "$(uname -s)" = "Darwin" ]; }

_pf_hint() {
    case "$1" in
        uv)
            if _pf_is_mac; then echo "brew install uv"
            else echo "curl -LsSf https://astral.sh/uv/install.sh | sh"; fi ;;
        pandoc)
            if _pf_is_mac; then echo "brew install pandoc"
            else echo "sudo dnf install pandoc"; fi ;;
        magick)
            if _pf_is_mac; then echo "brew install imagemagick"
            else echo "sudo dnf install ImageMagick"; fi ;;
        *)  echo "instale '$1'" ;;
    esac
}

# preflight [extra-tool ...]
# Returns 0 if everything is present, otherwise prints the full report and
# returns 1.
preflight() {
    local venv_py="$PY_DIR/.venv/bin/python"
    local venv_missing=0 need_uv=0 missing_tools="" t

    [ -x "$venv_py" ] || venv_missing=1
    if [ "$venv_missing" -eq 1 ] && ! command -v uv >/dev/null 2>&1; then
        need_uv=1
    fi

    for t in "$@"; do
        command -v "$t" >/dev/null 2>&1 || missing_tools="$missing_tools $t"
    done

    if [ "$venv_missing" -eq 0 ] && [ -z "$missing_tools" ]; then
        return 0
    fi

    {
        echo "Erro: faltam dependencias para rodar este script."
        echo
        local n=1
        if [ "$need_uv" -eq 1 ]; then
            echo "  $n) 'uv' nao encontrado (necessario para criar o ambiente Python)"
            echo "     $(_pf_hint uv)"
            n=$((n + 1))
        fi
        if [ "$venv_missing" -eq 1 ]; then
            echo "  $n) ambiente Python ausente em $PY_DIR/.venv"
            echo "     $SCRIPT_DIR/bootstrap.sh"
            n=$((n + 1))
        fi
        for t in $missing_tools; do
            echo "  $n) '$t' nao encontrado"
            echo "     $(_pf_hint "$t")"
            n=$((n + 1))
        done
        echo
        echo "Rode os comandos acima na ordem indicada e tente de novo."
    } >&2
    return 1
}
