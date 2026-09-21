#!/usr/bin/env bash
#
# migrar-fedora.sh
# Exporta e reinstala pacotes dnf, apps flatpak e extensoes do GNOME
# entre duas maquinas Fedora.
#
# Precisa ser executado a partir de um pendrive. Os dados exportados
# e o log de erros sao gravados no proprio pendrive.
#
# Uso: ./migrar-fedora.sh
#

set -uo pipefail

# ---------- localizacao do script ----------

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
BASE="$(dirname "$SCRIPT_PATH")"

# tudo fica escopado por usuario, para que o mesmo pendrive sirva
# a varios usuarios sem um sobrescrever o outro
USUARIO="$(id -un)"
PERFIL="$BASE/${USUARIO}-settings"

PASTA="$PERFIL/dados-migracao"
ARQUIVO="$PERFIL/migracao.tar.gz"
LOG="$PERFIL/errors.txt"

HOUVE_ERRO=0

# criada cedo para que o log tenha onde ser gravado
mkdir -p "$PERFIL" 2>/dev/null

# ---------- helpers ----------

info()  { printf '\n\033[1;34m==>\033[0m %s\n' "$1"; }
ok()    { printf '\033[1;32m  ok\033[0m %s\n' "$1"; }

aviso() {
    printf '\033[1;33m  !!\033[0m %s\n' "$1"
    registrar "AVISO" "$1"
}

erro() {
    printf '\033[1;31m  xx\033[0m %s\n' "$1" >&2
    registrar "ERRO" "$1"
}

registrar() {
    local nivel="$1" msg="$2"
    if [[ "$HOUVE_ERRO" -eq 0 ]]; then
        {
            echo "=========================================="
            echo "Log de migracao - $(date '+%Y-%m-%d %H:%M:%S')"
            echo "Host: $(hostname)  Fedora: $(rpm -E %fedora 2>/dev/null || echo '?')"
            echo "=========================================="
        } >> "$LOG" 2>/dev/null
        HOUVE_ERRO=1
    fi
    printf '[%s] %s: %s\n' "$(date '+%H:%M:%S')" "$nivel" "$msg" >> "$LOG" 2>/dev/null
}

tem() { command -v "$1" >/dev/null 2>&1; }

# ---------- aparencia (tema + papel de parede) ----------

# tira as aspas simples que o gsettings coloca nos valores
limpar() { sed "s/^'//; s/'$//" <<< "$1"; }

# converte file:///caminho%20com%20espaco em /caminho com espaco
uri_para_caminho() {
    local uri="$1"
    [[ "$uri" != file://* ]] && return 1
    uri="${uri#file://}"
    if tem python3; then
        python3 -c 'import sys,urllib.parse;print(urllib.parse.unquote(sys.argv[1]))' "$uri"
    else
        printf '%b\n' "${uri//%/\\x}"
    fi
}

exportar_aparencia() {
    info "Exportando tema e papel de parede"

    if ! tem gsettings; then
        aviso "gsettings nao encontrado, pulando aparencia"
        return
    fi

    local conf="$PASTA/aparencia.conf"
    : > "$conf"

    local esquema tema_gtk tema_icones fonte
    esquema="$(limpar "$(gsettings get org.gnome.desktop.interface color-scheme 2>/dev/null)")"
    tema_gtk="$(limpar "$(gsettings get org.gnome.desktop.interface gtk-theme 2>/dev/null)")"
    tema_icones="$(limpar "$(gsettings get org.gnome.desktop.interface icon-theme 2>/dev/null)")"
    fonte="$(limpar "$(gsettings get org.gnome.desktop.interface font-name 2>/dev/null)")"

    {
        echo "color-scheme=$esquema"
        echo "gtk-theme=$tema_gtk"
        echo "icon-theme=$tema_icones"
        echo "font-name=$fonte"
    } >> "$conf"

    case "$esquema" in
        prefer-dark)  ok "modo escuro" ;;
        prefer-light) ok "modo claro" ;;
        *)            ok "modo: ${esquema:-padrao}" ;;
    esac

    # papel de parede: claro, escuro e opcoes de enquadramento
    mkdir -p "$PASTA/wallpapers"

    local chave uri caminho nome
    for chave in picture-uri picture-uri-dark; do
        uri="$(limpar "$(gsettings get org.gnome.desktop.background "$chave" 2>/dev/null)")"
        if [[ -z "$uri" || "$uri" == "''" ]]; then
            echo "$chave=" >> "$conf"
            continue
        fi

        if caminho="$(uri_para_caminho "$uri")" && [[ -f "$caminho" ]]; then
            nome="$(basename "$caminho")"
            if cp -f "$caminho" "$PASTA/wallpapers/$nome" 2>/dev/null; then
                echo "$chave=$nome" >> "$conf"
                ok "$chave: $nome"
            else
                aviso "nao consegui copiar o papel de parede $caminho"
                echo "$chave=" >> "$conf"
            fi
        else
            # wallpaper do sistema ou uri nao-arquivo: guarda a uri original
            echo "$chave=URI:$uri" >> "$conf"
            ok "$chave: referencia do sistema"
        fi
    done

    local opcoes cor
    opcoes="$(limpar "$(gsettings get org.gnome.desktop.background picture-options 2>/dev/null)")"
    cor="$(limpar "$(gsettings get org.gnome.desktop.background primary-color 2>/dev/null)")"
    {
        echo "picture-options=$opcoes"
        echo "primary-color=$cor"
    } >> "$conf"
}

# ---------- configuracoes gerais do GNOME (inclui o que o Tweaks altera) ----------

# o Tweaks nao tem armazenamento proprio: ele escreve no dconf, junto
# com energia, notificacoes, acessibilidade e o resto das preferencias
CAMINHOS_DCONF=(
    "/org/gnome/desktop/"
    "/org/gnome/settings-daemon/"
    "/org/gnome/mutter/"
    "/org/gnome/system/"
    "/org/gnome/nautilus/"
    "/org/gnome/Console/"
    "/org/gnome/terminal/"
    "/org/gnome/software/"
    "/org/gtk/settings/"
    "/org/gtk/gtk4/settings/"
)

slug_dconf() {
    local p="$1"
    p="${p#/}"; p="${p%/}"
    echo "${p//\//-}"
}

exportar_config_gnome() {
    info "Exportando configuracoes do GNOME (Tweaks, atalhos, sistema)"

    if ! tem dconf; then
        aviso "dconf nao encontrado, pulando configuracoes do GNOME"
        return
    fi

    local pasta="$PASTA/dconf"
    mkdir -p "$pasta"

    local caminho arquivo salvos=0
    for caminho in "${CAMINHOS_DCONF[@]}"; do
        arquivo="$pasta/$(slug_dconf "$caminho").dconf"
        if dconf dump "$caminho" > "$arquivo" 2>/dev/null; then
            if [[ -s "$arquivo" ]]; then
                salvos=$((salvos + 1))
            else
                rm -f "$arquivo"
            fi
        else
            aviso "falha ao exportar $caminho"
        fi
    done
    ok "$salvos caminhos do dconf salvos"
}

importar_config_gnome() {
    local pasta="$PASTA/dconf"

    if [[ ! -d "$pasta" ]]; then
        aviso "pasta dconf nao encontrada, pulando configuracoes do GNOME"
        return
    fi

    if ! tem dconf; then
        aviso "dconf nao encontrado, pulando configuracoes do GNOME"
        return
    fi

    info "Restaurando configuracoes do GNOME"

    local caminho arquivo
    for caminho in "${CAMINHOS_DCONF[@]}"; do
        arquivo="$pasta/$(slug_dconf "$caminho").dconf"
        [[ -f "$arquivo" ]] || continue

        # backup do estado atual antes de sobrescrever
        dconf dump "$caminho" > "$pasta/$(slug_dconf "$caminho").backup.dconf" 2>/dev/null

        if dconf load "$caminho" < "$arquivo" 2>/dev/null; then
            ok "$caminho"
        else
            aviso "falha ao aplicar $caminho"
        fi
    done
}

# ---------- arquivos de configuracao fora do dconf ----------

# caminhos relativos ao $HOME
ARQUIVOS_CONFIG=(
    ".config/autostart"
    ".config/gtk-3.0"
    ".config/gtk-4.0"
    ".config/kitty"
    ".config/mpv"
    ".config/user-dirs.dirs"
    ".local/share/applications"
    ".local/share/icons"
    ".local/share/themes"
    ".themes"
    ".icons"
    ".bashrc"
    ".bash_aliases"
    ".profile"
    ".gitconfig"
)

exportar_arquivos_config() {
    info "Exportando arquivos de configuracao do usuario"

    local pasta="$PASTA/config-files"
    mkdir -p "$pasta"

    local item copiados=0
    for item in "${ARQUIVOS_CONFIG[@]}"; do
        [[ -e "$HOME/$item" ]] || continue
        mkdir -p "$pasta/$(dirname "$item")"
        if cp -a "$HOME/$item" "$pasta/$item" 2>/dev/null; then
            copiados=$((copiados + 1))
            ok "$item"
        else
            aviso "falha ao copiar $item"
        fi
    done

    if [[ "$copiados" -eq 0 ]]; then
        ok "nenhum arquivo de configuracao encontrado"
    fi
}

importar_arquivos_config() {
    local pasta="$PASTA/config-files"

    if [[ ! -d "$pasta" ]]; then
        aviso "pasta config-files nao encontrada, pulando"
        return
    fi

    info "Restaurando arquivos de configuracao do usuario"

    local backup="$HOME/.config-backup-migracao-$(date +%Y%m%d-%H%M%S)"
    local item restaurados=0

    for item in "${ARQUIVOS_CONFIG[@]}"; do
        [[ -e "$pasta/$item" ]] || continue

        # guarda o que ja existia antes de sobrescrever
        if [[ -e "$HOME/$item" ]]; then
            mkdir -p "$backup/$(dirname "$item")"
            cp -a "$HOME/$item" "$backup/$item" 2>/dev/null
        fi

        mkdir -p "$HOME/$(dirname "$item")"
        if cp -a "$pasta/$item" "$HOME/$item" 2>/dev/null; then
            restaurados=$((restaurados + 1))
            ok "$item"
        else
            aviso "falha ao restaurar $item"
        fi
    done

    if [[ -d "$backup" ]]; then
        echo "  Arquivos antigos guardados em: $backup"
    fi
    [[ "$restaurados" -eq 0 ]] && ok "nada para restaurar"
}

# ---------- configuracoes das extensoes ----------

exportar_config_extensoes() {
    info "Exportando configuracoes das extensoes"

    if ! tem dconf; then
        aviso "dconf nao encontrado, pulando configuracoes das extensoes"
        return
    fi

    local destino="$PASTA/extensoes-config.dconf"

    if dconf dump /org/gnome/shell/extensions/ > "$destino" 2>/dev/null; then
        if [[ -s "$destino" ]]; then
            ok "$(grep -c '^\[' "$destino") extensoes com configuracao salva"
        else
            ok "nenhuma configuracao personalizada encontrada"
        fi
    else
        aviso "falha ao exportar configuracoes das extensoes"
    fi

    # extensoes fixadas no dash e ordem dos favoritos
    local favoritos
    favoritos="$(gsettings get org.gnome.shell favorite-apps 2>/dev/null)"
    [[ -n "$favoritos" ]] && echo "$favoritos" > "$PASTA/favoritos.txt"
}

importar_config_extensoes() {
    local origem="$PASTA/extensoes-config.dconf"

    if [[ ! -f "$origem" ]]; then
        aviso "extensoes-config.dconf nao encontrado, pulando"
        return
    fi

    if ! tem dconf; then
        aviso "dconf nao encontrado, pulando configuracoes das extensoes"
        return
    fi

    if [[ ! -s "$origem" ]]; then
        ok "nenhuma configuracao de extensao para restaurar"
        return
    fi

    info "Restaurando configuracoes das extensoes"

    # backup do estado atual, caso queira reverter
    dconf dump /org/gnome/shell/extensions/ > "$PASTA/extensoes-config.backup.dconf" 2>/dev/null

    if dconf load /org/gnome/shell/extensions/ < "$origem" 2>/dev/null; then
        ok "configuracoes aplicadas"
    else
        aviso "falha ao aplicar configuracoes das extensoes"
    fi

    if [[ -f "$PASTA/favoritos.txt" ]]; then
        if gsettings set org.gnome.shell favorite-apps "$(cat "$PASTA/favoritos.txt")" 2>/dev/null; then
            ok "favoritos do dash restaurados"
        else
            aviso "falha ao restaurar os favoritos do dash"
        fi
    fi
}

importar_aparencia() {
    local conf="$PASTA/aparencia.conf"

    if [[ ! -f "$conf" ]]; then
        aviso "aparencia.conf nao encontrado, pulando tema e papel de parede"
        return
    fi

    if ! tem gsettings; then
        aviso "gsettings nao encontrado, pulando aparencia"
        return
    fi

    info "Restaurando tema e papel de parede"

    local destino="$HOME/.local/share/backgrounds/migracao"
    mkdir -p "$destino"

    local chave valor
    while IFS='=' read -r chave valor; do
        [[ -z "$chave" ]] && continue
        [[ -z "$valor" ]] && continue

        case "$chave" in
            color-scheme|gtk-theme|icon-theme|font-name)
                if gsettings set org.gnome.desktop.interface "$chave" "$valor" 2>/dev/null; then
                    ok "$chave: $valor"
                else
                    aviso "nao consegui aplicar $chave=$valor"
                fi
                ;;
            picture-uri|picture-uri-dark)
                local uri_final
                if [[ "$valor" == URI:* ]]; then
                    uri_final="${valor#URI:}"
                else
                    if [[ -f "$PASTA/wallpapers/$valor" ]]; then
                        cp -f "$PASTA/wallpapers/$valor" "$destino/$valor" 2>/dev/null \
                            || aviso "nao consegui copiar $valor para $destino"
                        uri_final="file://$destino/$valor"
                    else
                        aviso "papel de parede $valor nao esta no pendrive"
                        continue
                    fi
                fi
                if gsettings set org.gnome.desktop.background "$chave" "$uri_final" 2>/dev/null; then
                    ok "$chave aplicado"
                else
                    aviso "nao consegui aplicar $chave"
                fi
                ;;
            picture-options|primary-color)
                gsettings set org.gnome.desktop.background "$chave" "$valor" 2>/dev/null \
                    || aviso "nao consegui aplicar $chave=$valor"
                ;;
        esac
    done < "$conf"

    # o GDM/tela de bloqueio usa o mesmo wallpaper por padrao no Fedora
    local uri_claro
    uri_claro="$(gsettings get org.gnome.desktop.background picture-uri 2>/dev/null)"
    [[ -n "$uri_claro" ]] && gsettings set org.gnome.desktop.screensaver picture-uri \
        "$(limpar "$uri_claro")" 2>/dev/null
}

# ---------- verificacao de pendrive ----------

verificar_pendrive() {
    local origem disco transporte removivel

    origem="$(findmnt -no SOURCE --target "$BASE" 2>/dev/null)"
    if [[ -z "$origem" ]]; then
        printf '\033[1;31m  xx\033[0m Nao consegui identificar o dispositivo de %s\n' "$BASE" >&2
        exit 1
    fi

    # nome do disco pai (ex: sdb a partir de /dev/sdb1)
    disco="$(lsblk -no PKNAME "$origem" 2>/dev/null | head -n1)"
    [[ -z "$disco" ]] && disco="$(lsblk -no KNAME "$origem" 2>/dev/null | head -n1)"

    if [[ -z "$disco" ]]; then
        printf '\033[1;31m  xx\033[0m Nao consegui identificar o disco de %s\n' "$origem" >&2
        exit 1
    fi

    transporte="$(lsblk -dno TRAN "/dev/$disco" 2>/dev/null)"
    removivel="$(cat "/sys/block/$disco/removable" 2>/dev/null || echo 0)"

    if [[ "$transporte" == "usb" || "$removivel" == "1" ]]; then
        ok "rodando do dispositivo removivel /dev/$disco ($BASE)"
        return 0
    fi

    printf '\n\033[1;31m  xx  Este script precisa ser executado a partir de um pendrive.\033[0m\n' >&2
    printf '      Local atual: %s\n' "$BASE" >&2
    printf '      Dispositivo: /dev/%s (transporte: %s, removivel: %s)\n\n' \
        "$disco" "${transporte:-desconhecido}" "$removivel" >&2
    printf '      Copie o script para um pendrive e rode a partir de la.\n\n' >&2
    exit 1
}

# ---------- modo origem ----------

# ---------- listagem de pacotes dnf ----------

# tenta varias estrategias em cascata, porque a sintaxe mudou entre
# dnf4 e dnf5 e o campo "reason" nem sempre esta preenchido
listar_pacotes_dnf() {
    info "Listando pacotes instalados"

    local saida="$PASTA/dnf-pacotes.txt"
    local gerente=""
    : > "$saida"

    if tem dnf5; then
        gerente="dnf5"
    elif tem dnf; then
        gerente="dnf"
    else
        aviso "dnf nao encontrado, pulando"
        return
    fi

    # 1) opcao nativa --userinstalled
    "$gerente" repoquery --installed --userinstalled --qf '%{name}\n' 2>/dev/null \
        | grep -v '^$' | sort -u > "$saida"
    if [[ -s "$saida" ]]; then
        ok "$(wc -l < "$saida") pacotes (via --userinstalled)"
        return
    fi

    # 2) filtrar pelo campo reason
    "$gerente" repoquery --installed --qf '%{name}\t%{reason}\n' 2>/dev/null \
        | awk -F'\t' 'tolower($2) ~ /^(user|external user)$/ {print $1}' \
        | grep -v '^$' | sort -u > "$saida"
    if [[ -s "$saida" ]]; then
        ok "$(wc -l < "$saida") pacotes (via reason=user)"
        return
    fi

    # 3) historico de instalacoes do usuario
    "$gerente" history userinstalled 2>/dev/null \
        | awk '{print $1}' | sed 's/-[0-9].*$//' \
        | grep -v '^$' | grep -v '^Instalado\|^Installed\|^Package\|^Pacote' \
        | sort -u > "$saida"
    if [[ -s "$saida" ]]; then
        ok "$(wc -l < "$saida") pacotes (via history)"
        return
    fi

    # 4) ultimo recurso: tudo que o rpm conhece
    aviso "nao consegui separar o que foi instalado por voce; exportando tudo via rpm"
    rpm -qa --qf '%{NAME}\n' 2>/dev/null | grep -v '^$' | sort -u > "$saida"
    if [[ -s "$saida" ]]; then
        ok "$(wc -l < "$saida") pacotes (via rpm -qa, inclui dependencias)"
    else
        aviso "nenhum pacote encontrado por nenhum metodo"
    fi
}

exportar() {
    info "Exportando configuracao desta maquina"
    mkdir -p "$PASTA" || { erro "nao consegui criar $PASTA (pendrive somente leitura?)"; exit 1; }

    listar_pacotes_dnf

    if tem flatpak; then
        if flatpak list --app --columns=application > "$PASTA/flatpak-apps.txt"; then
            ok "$(wc -l < "$PASTA/flatpak-apps.txt") apps flatpak"
        else
            aviso "falha ao listar flatpaks"
        fi
    else
        aviso "flatpak nao encontrado, pulando"
        : > "$PASTA/flatpak-apps.txt"
    fi

    if tem gnome-extensions; then
        if gnome-extensions list --enabled > "$PASTA/gnome-extensions.txt"; then
            ok "$(wc -l < "$PASTA/gnome-extensions.txt") extensoes do GNOME"
        else
            aviso "falha ao listar extensoes do GNOME"
        fi
    else
        aviso "gnome-extensions nao encontrado, pulando"
        : > "$PASTA/gnome-extensions.txt"
    fi

    exportar_aparencia
    exportar_config_gnome
    exportar_config_extensoes
    exportar_arquivos_config

    if tar -czf "$ARQUIVO" -C "$PASTA" .; then
        ok "pacote gravado no pendrive"
    else
        erro "falha ao gravar $ARQUIVO"
        exit 1
    fi

    info "Pronto"
    echo "  Pacote gerado: $ARQUIVO"
    echo
    echo "  Leve o pendrive ate a outra maquina, rode este mesmo script de la"
    echo "  e escolha a opcao 2."
}

# ---------- modo destino ----------

importar() {
    # se nao houver pacote para este usuario, procura perfis de outros
    if [[ ! -f "$ARQUIVO" ]]; then
        local perfis=()
        local d
        for d in "$BASE"/*-settings; do
            [[ -f "$d/migracao.tar.gz" ]] && perfis+=("$d")
        done

        if [[ ${#perfis[@]} -eq 1 ]]; then
            PERFIL="${perfis[0]}"
            PASTA="$PERFIL/dados-migracao"
            ARQUIVO="$PERFIL/migracao.tar.gz"
            ok "usando o perfil $(basename "$PERFIL")"
        elif [[ ${#perfis[@]} -gt 1 ]]; then
            echo
            echo "  Varios perfis encontrados no pendrive:"
            local i=1
            for d in "${perfis[@]}"; do
                echo "    $i) $(basename "$d")"
                i=$((i + 1))
            done
            echo
            read -rp "  Qual usar? [1-${#perfis[@]}]: " idx
            if [[ "$idx" =~ ^[0-9]+$ ]] && (( idx >= 1 && idx <= ${#perfis[@]} )); then
                PERFIL="${perfis[$((idx - 1))]}"
                PASTA="$PERFIL/dados-migracao"
                ARQUIVO="$PERFIL/migracao.tar.gz"
                ok "usando o perfil $(basename "$PERFIL")"
            else
                erro "opcao invalida: $idx"
                exit 1
            fi
        fi
    fi

    if [[ ! -f "$ARQUIVO" ]]; then
        erro "nao encontrei nenhum pacote de migracao no pendrive"
        echo "  Rode a opcao 1 na maquina de origem primeiro."
        exit 1
    fi

    info "Extraindo pacote"
    mkdir -p "$PASTA"
    if tar -xzf "$ARQUIVO" -C "$PASTA"; then
        ok "extraido"
    else
        erro "falha ao extrair $ARQUIVO"
        exit 1
    fi

    info "Instalando repositorios RPM Fusion"
    local fedver
    fedver=$(rpm -E %fedora)
    if sudo dnf install -y \
        "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-${fedver}.noarch.rpm" \
        "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-${fedver}.noarch.rpm"
    then
        ok "RPM Fusion pronto"
    else
        aviso "RPM Fusion falhou, seguindo mesmo assim"
    fi

    if [[ -s "$PASTA/dnf-pacotes.txt" ]]; then
        info "Instalando pacotes dnf"
        if sudo dnf install -y --skip-unavailable $(cat "$PASTA/dnf-pacotes.txt"); then
            ok "pacotes dnf instalados"
        else
            aviso "alguns pacotes dnf falharam"
        fi
    else
        aviso "lista de pacotes dnf vazia, pulando"
    fi

    if [[ -s "$PASTA/flatpak-apps.txt" ]]; then
        info "Instalando apps flatpak"
        if ! flatpak remote-add --if-not-exists flathub \
            https://flathub.org/repo/flathub.flatpakrepo; then
            aviso "falha ao adicionar o remote flathub"
        fi
        while read -r app; do
            [[ -z "$app" ]] && continue
            if flatpak install -y flathub "$app" >/dev/null 2>&1; then
                ok "$app"
            else
                aviso "flatpak $app falhou"
            fi
        done < "$PASTA/flatpak-apps.txt"
    else
        aviso "lista de flatpaks vazia, pulando"
    fi

    if [[ -s "$PASTA/gnome-extensions.txt" ]]; then
        info "Instalando extensoes do GNOME"

        export PATH="$HOME/.local/bin:$PATH"

        if ! tem gext; then
            # o Fedora traz python3, mas nem sempre pip/pipx
            if ! tem python3; then
                sudo dnf install -y python3 || aviso "falha ao instalar python3"
            fi
            if ! tem pipx; then
                sudo dnf install -y pipx || aviso "falha ao instalar pipx"
            fi

            if tem pipx; then
                pipx ensurepath >/dev/null 2>&1
                export PATH="$HOME/.local/bin:$PATH"
                pipx install gnome-extensions-cli >/dev/null 2>&1 \
                    || aviso "falha ao instalar gnome-extensions-cli via pipx"
            else
                # ultimo recurso: pip direto
                if ! tem pip && ! tem pip3; then
                    sudo dnf install -y python3-pip || aviso "falha ao instalar python3-pip"
                fi
                python3 -m pip install --user --break-system-packages \
                    gnome-extensions-cli >/dev/null 2>&1 \
                    || aviso "falha ao instalar gnome-extensions-cli via pip"
            fi
            export PATH="$HOME/.local/bin:$PATH"
        fi
        if tem gext; then
            while read -r ext; do
                [[ -z "$ext" ]] && continue
                if gext install "$ext" >/dev/null 2>&1; then
                    ok "$ext"
                else
                    aviso "extensao $ext falhou (pode nao ser compativel com esta versao do GNOME)"
                fi
            done < "$PASTA/gnome-extensions.txt"
        else
            aviso "gext indisponivel, pulando extensoes"
        fi
    else
        aviso "lista de extensoes vazia, pulando"
    fi

    info "Instalando GNOME Tweaks e utilitarios de configuracao"
    if sudo dnf install -y gnome-tweaks dconf-editor; then
        ok "gnome-tweaks pronto"
    else
        aviso "falha ao instalar gnome-tweaks"
    fi

    importar_arquivos_config
    importar_config_gnome
    importar_config_extensoes
    importar_aparencia

    info "Migracao concluida"
    echo "  Faca logout e login para as extensoes do GNOME carregarem."
}

# ---------- resumo final ----------

resumo() {
    if [[ "$HOUVE_ERRO" -eq 1 ]]; then
        printf '\n\033[1;33m  Ocorreram problemas. Detalhes em: %s\033[0m\n\n' "$LOG"
    else
        printf '\n\033[1;32m  Nenhum erro registrado.\033[0m\n\n'
    fi
}

trap resumo EXIT

# ---------- menu ----------

echo
echo "  Migracao de sistema Fedora"
echo "  --------------------------"

verificar_pendrive

echo
echo "  1) Este e o PC de ORIGEM   (exportar o que esta instalado)"
echo "  2) Este e o PC de DESTINO  (instalar tudo a partir do pacote)"
echo "  3) Sair"
echo
read -rp "  Escolha [1/2/3]: " escolha

case "$escolha" in
    1) exportar ;;
    2) importar ;;
    3) echo "  Saindo."; exit 0 ;;
    *) erro "opcao invalida: $escolha"; exit 1 ;;
esac
