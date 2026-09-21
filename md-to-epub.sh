#!/bin/bash

echo "============================================="
echo "   GERADOR DE EPUB PARA KINDLE INTERATIVO    "
echo "============================================="

# 1. Detecta o Sistema Operacional para a dica de instalação
if [[ "$OSTYPE" == "darwin"* ]]; then
    DICA_INSTALACAO="brew install pandoc imagemagick"
else
    DICA_INSTALACAO="sudo dnf install pandoc ImageMagick"
fi

# 2. Verifica se as ferramentas essenciais estão instaladas
if ! command -v pandoc &> /dev/null || ! command -v magick &> /dev/null; then
    echo "❌ ERRO: Pandoc ou ImageMagick nao encontrados."
    echo "Por favor, instale as dependencias: $DICA_INSTALACAO"
    echo "============================================="
    read -p "Pressione [Enter] para fechar..."
    exit 1
fi

# -------------------------------------------------------
# 🌟 RESOLUÇÃO DA FONTE CENTRALIZADA (Subpasta fonts)
# -------------------------------------------------------
# Captura o caminho REAL e ABSOLUTO da pasta do script antes do 'cd'
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FONTS_DIR="$SCRIPT_DIR/lib/fonts"

# Busca automaticamente os dois nomes mais comuns do arquivo de fonte na subpasta fonts
if [ -f "$FONTS_DIR/JetBrainsMono.ttf" ]; then
    FONTE_ALVO="$FONTS_DIR/JetBrainsMono.ttf"
elif [ -f "$FONTS_DIR/JetBrainsMono-Regular.ttf" ]; then
    FONTE_ALVO="$FONTS_DIR/JetBrainsMono-Regular.ttf"
else
    # Se não achar nenhuma na subpasta fonts, assume o nome padrão para não quebrar
    FONTE_ALVO="$FONTS_DIR/JetBrainsMono.ttf"
fi

# Descobre o nome limpo do arquivo (ex: JetBrainsMono.ttf) para usar no CSS interno
BASENAME_FONTE=$(basename "$FONTE_ALVO")
# -------------------------------------------------------

# -------------------------------------------------------
# TRATAMENTO INTELIGENTE DE ENTRADA (Mesa/Pasta/Arquivo)
# -------------------------------------------------------
echo "📁 Onde está o conteúdo?"
read -r -p "   Arraste a pasta OU o arquivo .md aqui (Enter para a pasta atual): " input_dir

if [ -z "$input_dir" ]; then
    TARGET_DIR="$PWD"
    MODO_ARQUIVO=false
else
    CLEANED_PATH=$(echo "$input_dir" | sed 's/"//g' | sed "s/'//g" | sed 's/\\ / /g')
    
    if [ -f "$CLEANED_PATH" ]; then
        TARGET_DIR=$(dirname "$CLEANED_PATH")
        ARQUIVO_ALVO=$(basename "$CLEANED_PATH")
        MODO_ARQUIVO=true
    elif [ -d "$CLEANED_PATH" ]; then
        TARGET_DIR="$CLEANED_PATH"
        MODO_ARQUIVO=false
    else
        echo "❌ ERRO: O caminho fornecido nao existe ou esta incorreto."
        echo "============================================="
        read -p "Pressione [Enter] para fechar..."
        exit 1
    fi
fi

# Agora podemos mudar de pasta com segurança, pois o caminho da fonte já está travado!
cd "$TARGET_DIR"

# Parking lot (Seu histórico de estilos guardado)

# 3. Cria o arquivo CSS profissional temporariamente
# Removidas as aspas de 'EOF' para permitir que o script injete o nome correto da fonte
cat << EOF > kindle_style_tmp.css
/* =======================================================
   0. MAPEAMENTO DA FONTE (Dinamizado com o nome real do arquivo)
   ======================================================= */
@font-face {
    font-family: 'JetBrains Mono';
    font-style: normal;
    font-weight: normal;
    src: url('../fonts/${BASENAME_FONTE}');
}

/* Antídoto para manter o texto normal em serifa (Bookerly) */
body, p, li {
    font-family: serif;
}

/* =======================================================
   1. HEADERS (Margens bem reduzidas como você pediu)
   ======================================================= */
h1, h2, h3 {
    margin-top: 0.8em !important;
    margin-bottom: 0.2em !important;
}

/* =======================================================
   2. REGRAS PARA IMAGENS (O Xeque-Mate da Amazon)
   ======================================================= */
img {
    max-width: 100% !important;
    height: auto !important;
    display: block !important;
    margin: 1em auto !important;
}

/* =======================================================
   3. ADDOMESTICANDO A FONTE (Versão JetBrains Mono Isolada)
   ======================================================= */
pre { font-family: 'JetBrains Mono', monospace !important; }
code { font-family: 'JetBrains Mono', monospace !important; }

pre * { font-family: 'JetBrains Mono', monospace !important; }
code * { font-family: 'JetBrains Mono', monospace !important; }

/* Bloco de Código - Layout Geral */
pre, div.sourceCode {
    background-color: #f5f5f5 !important;
    border: 1px solid #e0e0e0 !important;
    padding: 0.4em !important;
    margin: 0.8em 0 !important;
    white-space: pre-wrap !important;
    word-wrap: break-word !important;
    overflow-wrap: break-word !important;
}

pre, code {
    line-height: 1.1 !important; 
    text-indent: 0 !important;
    text-align: left !important;
    font-size: 90% !important; 
}

pre > code > span {
    display: inline !important;
    line-height: 1.1 !important;
}

/* Código inline no meio do texto */
p > code {
    background-color: #f5f5f5 !important;
    padding: 1px 3px !important;
}
EOF

if [ "$MODO_ARQUIVO" = true ]; then
    LISTA_ARQUIVOS=("$ARQUIVO_ALVO")
else
    LISTA_ARQUIVOS=(*.md)
fi

# 4. Processamento dos arquivos
encontrou_arquivos=false

for arquivo in "${LISTA_ARQUIVOS[@]}"; do
    [ -e "$arquivo" ] || continue
    [[ "$arquivo" == *"_tmp.md" ]] && continue
    
    encontrou_arquivos=true
    nome_sem_extensao="${arquivo%.*}"
    echo "---------------------------------------------"
    
    # INTERCEPTADOR E RENDERIZADOR NATIVO DE MERMAID
    echo "... Processando estruturas de '$arquivo' ..."
    in_mermaid=false
    mermaid_code=""
    mermaid_id=1
    rm -f kindle_processed_tmp.md
    
    while IFS= read -r linha || [ -n "$linha" ]; do
        if [[ "$linha" =~ ^\`\`\`mermaid ]]; then
            in_mermaid=true
            mermaid_code=""
            continue
        fi
        
        if [ "$in_mermaid" = true ]; then
            if [[ "$linha" =~ ^\`\`\` ]]; then
                in_mermaid=false
                json_safe_code=$(echo -n "$mermaid_code" | sed 's/\\/\\\\/g' | sed 's/"/\\"/g' | awk '{printf "%s\\n", $0}')
                json_packet="{\"code\":\"$json_safe_code\",\"mermaid\":{\"theme\":\"default\"}}"
                b64_encoded=$(echo -n "$json_packet" | base64 | tr -d '\n' | sed 's/+/%2B/g; s/\//%2F/g; s/=/%3D/g')
                M_IMG="kmermaid_${mermaid_id}.png"
                curl -s -k -L "https://mermaid.ink/img/${b64_encoded}" -o "mraw_tmp_${mermaid_id}"
                magick "mraw_tmp_${mermaid_id}" -strip -colorspace sRGB "$M_IMG" 2>/dev/null
                rm -f "mraw_tmp_${mermaid_id}"
                
                if [ -f "$M_IMG" ]; then
                    echo " ![$M_IMG]($M_IMG)" >> kindle_processed_tmp.md
                    ((mermaid_id++))
                else
                    echo "\`\`\`text" >> kindle_processed_tmp.md
                    echo "$mermaid_code" >> kindle_processed_tmp.md
                    echo "\`\`\`" >> kindle_processed_tmp.md
                fi
            else
                if [ -z "$mermaid_code" ]; then mermaid_code="$linha"; else mermaid_code="$mermaid_code"$'\n'"$linha"; fi
            fi
        else
            echo "$linha" >> kindle_processed_tmp.md
        fi
    done < "$arquivo"
    
    # Captura de imagens normais
    urls_imagens=$(grep -oE 'https?://[^"'\'' )]+' kindle_processed_tmp.md | grep -Ei '\.(png|jpg|jpeg|webp|avif|gif)' | sort -u)
    img_id=1
    for url in $urls_imagens; do
        IMG_FINAL="kimg_${img_id}.png"
        curl -s -k -L "$url" -o "raw_tmp_${img_id}"
        magick "raw_tmp_${img_id}" -strip -colorspace sRGB "$IMG_FINAL" 2>/dev/null
        rm -f "raw_tmp_${img_id}"
        if [ -f "$IMG_FINAL" ]; then
            export OLD_URL="$url"
            export NEW_PATH="$IMG_FINAL"
            awk 'BEGIN {old=ENVIRON["OLD_URL"]; new=ENVIRON["NEW_PATH"]; len=length(old)} {while(pos=index($0,old)){$0=substr($0,1,pos-1) new substr($0,pos+len)}print}' kindle_processed_tmp.md > kindle_processed.tmp && mv kindle_processed.tmp kindle_processed_tmp.md
            ((img_id++))
        fi
    done

    # Verifica se o arquivo da fonte realmente existe antes de chamar o Pandoc
    if [ ! -f "$FONTE_ALVO" ]; then
        echo "❌ ERRO: O arquivo de fonte '$BASENAME_FONTE' nao foi encontrado na pasta de fontes:"
        echo "   -> $FONTS_DIR"
        echo "   A conversao sera feita sem embutir a fonte."
        PARAM_FONTE=""
    else
        PARAM_FONTE="--epub-embed-font=$FONTE_ALVO"
    fi

    if [ "$(head -n 1 "$arquivo")" = "---" ]; then
        echo "✅ '$arquivo' possui YAML. Compilando com fonte centralizada..."
        pandoc kindle_processed_tmp.md $PARAM_FONTE -M document-css=false -M monofont="JetBrains Mono" --css=kindle_style_tmp.css -o "$nome_sem_extensao.epub"
    else
        echo "🔍 '$arquivo' não tem YAML. Configure ou pule:"
        read -p "   📝 Título (Enter para '$nome_sem_extensao' | 'S' para pular): " input_title
        if [[ "$input_title" == "s" || "$input_title" == "S" ]]; then
            echo "   ⏭️  Pulando..."
            rm -f kindle_processed_tmp.md kimg_*.png kmermaid_*.png
            continue
        fi
        title="${input_title:-$nome_sem_extensao}"
        
        usuario_sistema="${USER:-Unknown}"
        read -p "   👤 Autor (Enter para '$usuario_sistema'): " input_author
        author="${input_author:-$usuario_sistema}"
        
        while true; do
            read -p "   🌐 Idioma - [P]ortuguês ou [E]nglish? (P/E): " input_lang
            input_lang=$(echo "$input_lang" | tr '[:lower:]' '[:upper:]')
            if [ "$input_lang" = "P" ] || [ -z "$input_lang" ]; then lang="pt-BR"; break;
            elif [ "$input_lang" = "E" ]; then lang="en-US"; break;
            else echo "      ❌ Opção inválida."; fi
        done
        
        echo "⏳ Injetando metadados e gerando livro..."
        cat << EOF > kindle_final_tmp.md
---
title: "$title"
author: "$author"
lang: $lang
---
EOF
        cat kindle_processed_tmp.md >> kindle_final_tmp.md
        pandoc kindle_final_tmp.md $PARAM_FONTE -M document-css=false -M monofont="JetBrains Mono" --css=kindle_style_tmp.css -o "$nome_sem_extensao.epub"
        rm -f kindle_final_tmp.md
    fi
    rm -f kindle_processed_tmp.md kimg_*.png kmermaid_*.png
done

rm -f kindle_style_tmp.css
echo "============================================="
echo "✨ PROCESSO CONCLUÍDO COM SUCESSO!"
echo "============================================="
read -p "Pressione [Enter] para fechar..."
