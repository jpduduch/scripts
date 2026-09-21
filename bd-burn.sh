#!/usr/bin/env bash
#
# gravar_bd.sh - grava uma pasta num disco otico (BD-R/DVD/CD) via xorriso,
# calculando antes o tamanho da imagem e o espaco livre no disco.
#
# Uso: ./gravar_bd.sh /caminho/da/pasta [dispositivo] [rotulo]
#   dispositivo padrao: /dev/sr0
#   rotulo: se nao for passado, o script pergunta

set -euo pipefail

SRC="${1:-}"
DEV="${2:-/dev/sr0}"
LABEL="${3:-}"

uso() {
  echo "Uso: $0 /caminho/da/pasta [dispositivo] [rotulo]"
  echo "  dispositivo padrao: /dev/sr0"
  echo "  rotulo: se nao for passado, o script pergunta"
  exit 1
}

[ -n "$SRC" ] || uso
[ -d "$SRC" ] || { echo "Erro: pasta '$SRC' nao existe."; exit 1; }
[ -e "$DEV" ] || { echo "Erro: dispositivo '$DEV' nao existe. Rode 'ls /dev/sr*' pra conferir."; exit 1; }
command -v xorriso >/dev/null || { echo "Erro: xorriso nao esta instalado (sudo dnf install xorriso)."; exit 1; }

if [ -z "$LABEL" ]; then
  read -p "Rotulo do disco [DISCO]: " LABEL
  LABEL="${LABEL:-DISCO}"
fi

bytes_para_humano() {
  awk -v b="$1" 'BEGIN{ printf "%.2f MB (%d bytes)", b/1048576, b }'
}

converter_para_bytes() {
  local val="$1"
  if [[ "$val" =~ ^([0-9]+(\.[0-9]+)?)([kmgt])?$ ]]; then
    local num="${BASH_REMATCH[1]}" unit="${BASH_REMATCH[3]}"
    awk -v n="$num" -v u="$unit" 'BEGIN{
      mult = 1
      if (u == "k") mult = 1024
      else if (u == "m") mult = 1024*1024
      else if (u == "g") mult = 1024*1024*1024
      else if (u == "t") mult = 1024*1024*1024*1024
      printf "%d", n * mult
    }'
  else
    echo 0
  fi
}

echo "Calculando tamanho da imagem..."
BLOCOS=$(xorriso -as mkisofs -print-size -quiet -R -J -iso-level 3 "$SRC")
TAMANHO_IMAGEM=$((BLOCOS * 2048))

echo "Consultando espaco livre em $DEV..."
TOC_SAIDA=$(xorriso -outdev "$DEV" -toc 2>/dev/null || true)
LINHA_STATUS=$(echo "$TOC_SAIDA" | grep "Media status" || true)
LINHA_TOC=$(echo "$TOC_SAIDA" | grep "Media summary" || true)
[ -n "$LINHA_STATUS" ] && echo "$LINHA_STATUS"
[ -n "$LINHA_TOC" ] && echo "$LINHA_TOC"

if [ -z "$LINHA_TOC" ]; then
  echo "Aviso: nao consegui ler a midia em $DEV (disco ausente ou nao gravavel?)."
  echo "Tamanho da pasta: $(bytes_para_humano "$TAMANHO_IMAGEM")"
  read -p "Quer continuar mesmo assim, sem checar o espaco livre? [s/N] " RESP
  [[ "$RESP" =~ ^[sS]$ ]] || exit 1
else
  LIVRE_RAW=$(echo "$LINHA_TOC" | grep -oP '[0-9]+(?:\.[0-9]+)?[kmgt]?(?= free)')
  ESPACO_LIVRE=$(converter_para_bytes "$LIVRE_RAW")

  echo "Tamanho da pasta:  $(bytes_para_humano "$TAMANHO_IMAGEM")"
  echo "Espaco livre:      $(bytes_para_humano "$ESPACO_LIVRE")"

  if [ "$TAMANHO_IMAGEM" -gt "$ESPACO_LIVRE" ]; then
    EXCESSO=$((TAMANHO_IMAGEM - ESPACO_LIVRE))
    echo "Nao cabe. Excedendo em $(bytes_para_humano "$EXCESSO")."
    exit 1
  fi

  SOBRA=$((ESPACO_LIVRE - TAMANHO_IMAGEM))
  echo "Cabe. Sobram $(bytes_para_humano "$SOBRA") de folga."
fi

read -p "Gravar agora em $DEV? [s/N] " CONFIRMA
[[ "$CONFIRMA" =~ ^[sS]$ ]] || { echo "Cancelado."; exit 0; }

echo "Gravando..."
xorriso -as mkisofs -quiet -R -J -iso-level 3 -V "$LABEL" "$SRC" | xorriso -as cdrecord -v dev="$DEV" -eject -

echo "Gravacao concluida."
