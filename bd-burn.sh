#!/usr/bin/env bash
#
# bd-burn.sh - grava um arquivo ou uma pasta num disco otico (BD-R/DVD/CD) via
# xorriso. Antes confere se cabe (o proprio xorriso faz a conta, com o espaco
# do sistema de arquivos); depois le o disco de volta e compara cada arquivo
# com o MD5 gravado junto.
#
# Um disco com sessoes anteriores ganha uma sessao nova: o que ja esta nele
# continua la, e um nome que ja existe no disco nao e sobrescrito.
#
# Uso: bd-burn.sh [opcoes] ORIGEM [dispositivo] [rotulo]   (veja --help)

set -euo pipefail
# Ponto decimal, seja qual for o idioma do sistema.
export LC_NUMERIC=C

SRC=""
DEV=""
LABEL=""
NAME=""
YES=no
SPEED=""
EJECT=yes
MODE=burn

# O que fica livre depois de gravar: o xorriso avisa que o numero real pode
# ser alguns MB menor que o previsto.
SLACK=$((16 * 1024 * 1024))
# ISO nivel 3 aceita arquivos acima de 4 GiB; Joliet com nomes longos.
ISO_OPTS=(-joliet on -compliance iso_9660_level=3:joliet_long_names)
NO_FIT=3

log() { printf '[bd-burn %s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
die() { log "ERRO: $1"; exit "${2:-1}"; }
human() { awk -v b="$1" 'BEGIN { printf "%.2f GiB", b / 1073741824 }'; }

usage() {
    cat <<HELP
Uso: ${0##*/} [opcoes] ORIGEM [dispositivo] [rotulo]

Grava ORIGEM num disco otico e confere a gravacao lendo o disco de volta.
  ORIGEM pasta    o conteudo dela vai pra raiz do disco
  ORIGEM arquivo  vai pra raiz do disco (com --name, com outro nome)
Um disco ja usado ganha uma sessao nova; nada que esta nele e sobrescrito.

Opcoes:
  --device DEV   drive (padrao: /dev/sr0, senao o primeiro /dev/sr*);
                 stdio:/caminho/imagem.iso grava num arquivo (testes)
  --label TEXTO  rotulo do disco, ate 32 caracteres (padrao: pergunta, ou
                 o nome da ORIGEM com --yes)
  --name NOME    nome do arquivo no disco (so com ORIGEM arquivo)
  --speed N      grava a no maximo Nx (ex.: 4); padrao: a maxima do drive.
                 Mais devagar e mais seguro em drive USB.
  --no-eject     nao ejeta o disco no fim
  -y, --yes      nao pergunta nada
  --free         so mostra o espaco livre no disco, em bytes, e sai
  --check        so diz se ORIGEM cabe no disco, e sai (0 cabe, 3 nao cabe)
  -h, --help     este texto

Saida: 0 gravado e conferido; 3 nao cabe; 1 qualquer outro erro.
HELP
}

# --------------------------------------------------------------- argumentos

parse_args() {
    local -a pos=()
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help) usage; exit 0 ;;
            --device|--label|--name|--speed)
                [[ $# -ge 2 && -n $2 ]] || die "Falta o valor de $1."
                case $1 in
                    --device) DEV=$2 ;; --label) LABEL=$2 ;;
                    --name) NAME=$2 ;; --speed) SPEED=$2 ;;
                esac
                shift 2 ;;
            -y|--yes) YES=yes; shift ;;
            --no-eject) EJECT=no; shift ;;
            --free) MODE=free; shift ;;
            --check) MODE=check; shift ;;
            --) shift; pos+=("$@"); break ;;
            -*) die "Opcao desconhecida: $1 (veja --help)." ;;
            *) pos+=("$1"); shift ;;
        esac
    done
    # Forma antiga, que continua valendo: ORIGEM [dispositivo] [rotulo].
    [[ ${#pos[@]} -le 3 ]] || die "Argumentos demais (veja --help)."
    SRC=${pos[0]:-}
    [[ -z ${pos[1]:-} ]] || DEV=${pos[1]}
    [[ -z ${pos[2]:-} ]] || LABEL=${pos[2]}

    if [[ $MODE != free ]]; then
        [[ -n $SRC ]] || { usage >&2; exit 1; }
        [[ -e $SRC ]] || die "'$SRC' nao existe."
        SRC=$(realpath -- "$SRC")
        if [[ -d $SRC ]]; then
            [[ -z $NAME ]] || die "--name so vale para um arquivo, nao para uma pasta."
            [[ -n $(find "$SRC" -mindepth 1 -print -quit) ]] || die "A pasta '$SRC' esta vazia."
        elif [[ -f $SRC ]]; then
            NAME=${NAME:-${SRC##*/}}
            [[ $NAME != */* ]] || die "--name nao pode ter '/': $NAME"
        else
            die "'$SRC' nao e arquivo nem pasta."
        fi
    fi
    [[ -z $SPEED || $SPEED =~ ^[0-9]+(\.[0-9]+)?$ ]] || die "--speed quer um numero, ex.: 4"
}

pick_device() {
    if [[ -z $DEV ]]; then
        DEV=/dev/sr0
        [[ -e $DEV ]] || DEV=$(compgen -G '/dev/sr*' | head -1 || true)
        [[ -n $DEV ]] || DEV=/dev/sr0
    fi
    [[ $DEV == stdio:* || -e $DEV ]] || die "Nao existe drive em $DEV. Rode 'ls /dev/sr*' pra conferir."
    command -v xorriso >/dev/null || die "xorriso nao esta instalado (sudo dnf install xorriso)."
}

# --------------------------------------------------------------------- disco

# Poe em FREE o espaco livre em bytes (e o tipo de midia em MEDIA_TYPE);
# falha sem disco gravavel.
media_free() {
    local out sectors
    out=$(xorriso -outdev "$DEV" -tell_media_space 2>&1) || true
    MEDIA_STATUS=$(grep -m1 '^Media status' <<< "$out" || true)
    MEDIA_TYPE=$(grep -m1 -oP '^Media current:\s*\K\S+' <<< "$out" || true)
    sectors=$(grep -oP '^Media space\s*:\s*\K[0-9]+(?=s)' <<< "$out" || true)
    [[ -n $sectors && $sectors -gt 0 ]] || return 1
    FREE=$((sectors * 2048))
}

# Onde ORIGEM vai parar no disco.
map_args() {
    if [[ -d $SRC ]]; then
        printf '%s\n' -map "$SRC" /
    else
        printf '%s\n' -map "$SRC" "/$NAME"
    fi
}

# Os caminhos no disco a conferir: o arquivo, ou o que a pasta tem na raiz.
disc_paths() {
    local entry
    if [[ -d $SRC ]]; then
        while IFS= read -r -d '' entry; do
            printf '/%s\n' "${entry##*/}"
        done < <(find "$SRC" -mindepth 1 -maxdepth 1 -print0)
    else
        printf '/%s\n' "$NAME"
    fi
}

# Mostra quantos bytes sobrariam depois de gravar ORIGEM (negativo se nao
# cabe). O xorriso faz a conta com o sistema de arquivos e as sessoes
# anteriores; -rollback_end garante que nada e gravado.
space_after() {
    local out after
    local -a map
    mapfile -t map < <(map_args)
    out=$(xorriso -dev "$DEV" "${ISO_OPTS[@]}" "${map[@]}" \
        -tell_media_space -rollback_end 2>&1) || true
    after=$(grep -oP '^After commit\s*:\s*\K-?[0-9]+(?=s)' <<< "$out" || true)
    [[ -n $after ]] || { log "$out"; return 1; }
    printf '%s\n' $((after * 2048))
}

source_bytes() { du -sb -- "$SRC" | cut -f1; }

# A velocidade no formato do xorriso: o sufixo diz a unidade (b = 1x de BD,
# d = 1x de DVD, c = 1x de CD).
speed_arg() {
    case $MEDIA_TYPE in
        BD*) printf '%sb\n' "$SPEED" ;;
        DVD*) printf '%sd\n' "$SPEED" ;;
        CD*) printf '%sc\n' "$SPEED" ;;
        *) printf '%s\n' "$SPEED" ;;
    esac
}

burn() {
    local -a map speed=()
    mapfile -t map < <(map_args)
    if [[ -n $SPEED ]]; then speed=(-speed "$(speed_arg)"); fi
    log "Gravando em $DEV (rotulo '$LABEL')..."
    xorriso -abort_on FAILURE -md5 on -dev "$DEV" "${speed[@]}" -overwrite off \
        -volid "$LABEL" "${ISO_OPTS[@]}" "${map[@]}" -commit ||
        die "A gravacao falhou."
}

# Le de volta o que foi gravado e compara com os MD5 gravados junto.
verify() {
    local out
    local -a paths
    mapfile -t paths < <(disc_paths)
    log "Lendo o disco de volta pra conferir..."
    if ! out=$(xorriso -md5 on -indev "$DEV" -return_with FAILURE 32 \
        -check_md5_r FAILURE "${paths[@]}" -- 2>&1) ||
        ! grep -q 'checksums match' <<< "$out"; then
        log "$out"
        die "O disco nao confere com a origem (MD5 diferente)."
    fi
    log "Conferido: tudo o que foi gravado bate com o MD5."
}

# ---------------------------------------------------------------------- main

ask() {
    local reply
    read -r -p "$1" reply < /dev/tty || reply=''
    printf '%s\n' "$reply"
}

main() {
    parse_args "$@"
    pick_device

    # Um disco estragado no meio da gravacao nao tem volta: segura a suspensao.
    if [[ $MODE == burn && -z ${BD_INHIBITED:-} ]] && command -v systemd-inhibit >/dev/null; then
        BD_INHIBITED=1 exec systemd-inhibit --what=sleep:idle --who=bd-burn \
            --why="Gravando um disco" bash "${BASH_SOURCE[0]}" "$@"
    fi

    media_free || die "Nao tem disco gravavel em $DEV (ausente, fechado ou nao gravavel?)."
    if [[ $MODE == free ]]; then
        printf '%s\n' "$FREE"
        return 0
    fi

    local after
    after=$(space_after) || die "Nao consegui calcular se '${SRC##*/}' cabe no disco."
    [[ -z $MEDIA_STATUS ]] || log "$MEDIA_STATUS"
    log "Tamanho da origem: $(human "$(source_bytes)")"
    log "Espaco livre:      $(human "$FREE")"
    if (( after < SLACK )); then
        log "Nao cabe: sobrariam $(human "$after"), e e preciso deixar ao menos $(human "$SLACK")."
        exit "$NO_FIT"
    fi
    log "Cabe. Sobram $(human "$after") depois de gravar."
    [[ $MODE != check ]] || return 0

    if [[ -z $LABEL ]]; then
        local default=${SRC##*/}
        [[ -d $SRC ]] || default=${default%.*}
        # Espaco e afins dao um nome ruim pro ponto de montagem automatico.
        default=${default//[^A-Za-z0-9_-]/_}
        LABEL=${default:0:32}
        if [[ $YES == no ]]; then
            LABEL=$(ask "Rotulo do disco [$LABEL]: ")
            LABEL=${LABEL:-${default:0:32}}
        fi
    fi
    if [[ ${#LABEL} -gt 32 ]]; then
        LABEL=${LABEL:0:32}
        log "O rotulo foi cortado em 32 caracteres: $LABEL"
    fi

    if [[ $YES == no ]]; then
        [[ $(ask "Gravar agora em $DEV? [s/N] ") =~ ^[sS]$ ]] || { log "Cancelado."; exit 0; }
    fi

    burn
    verify
    if [[ $EJECT == yes ]]; then
        xorriso -outdev "$DEV" -eject all >/dev/null 2>&1 || true
    fi
    log "Gravacao concluida e conferida."
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
