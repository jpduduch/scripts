# font-fetcher

CLI que baixa as fontes (`@font-face`) usadas por uma ou mais páginas web.

## O que faz

1. Recebe uma ou mais URLs.
2. Descobre os arquivos `.css` da página (`<link rel="stylesheet">`, blocos
   `<style>` e `@import` aninhados).
3. Procura regras `@font-face` dentro desses CSS.
4. Resolve o caminho completo de cada arquivo de fonte e faz o download.
5. Salva cada fonte em `~/Desktop/fonts/<família>/`. Variantes que
   compartilham a mesma família-mãe ficam juntas: `JetBrains Sans`,
   `JetBrainsMono` e `JetBrainsMonoItalic` vão todas para a pasta `JetBrains`.
   Famílias sem relação geram pastas separadas. Fontes sem `font-family` na
   regra caem numa pasta com o nome do host.

O download **sobrescreve** (replace): fontes já presentes na pasta de uma
execução anterior são substituídas pelas novas. Isso garante que correções de
conversão sejam reaplicadas a cada execução, sem acumular duplicatas.

Os arquivos são nomeados a partir do `font-family` (+ peso e estilo) declarado
na regra `@font-face`, então uma URL obscura como `kl53453kl.woff` vira algo
como `JetBrainsMono-Bold.woff`. Se a regra não tiver `font-family`, o nome da
URL é usado como fallback.

Compatível com Mac e Linux Fedora.

## Requisitos

- [uv](https://docs.astral.sh/uv/) instalado. As dependências Python
  (`requests`, `beautifulsoup4`) são declaradas no próprio script (PEP 723) e
  o `uv` cuida do ambiente automaticamente.

Instalar o `uv`:

```bash
# Mac / Linux
curl -LsSf https://astral.sh/uv/install.sh | sh
```

## Uso

```bash
./fetch-fonts.sh https://exemplo.com

# várias URLs de uma vez
./fetch-fonts.sh https://a.com https://b.com

# diretório de saída customizado
./fetch-fonts.sh -o ~/minhas-fontes https://exemplo.com

# converte as fontes baixadas (estáticas -> .otf; variáveis mantidas)
./fetch-fonts.sh --convert https://exemplo.com
```

## Conversão (`--convert` / `-c`)

Com `--convert`, as fontes estáticas viram `.otf` e as variáveis são mantidas
com seus eixos:

- **woff / woff2** → o invólucro de compressão é removido.
- **eot** → a fonte SFNT embutida é extraída do invólucro EOT e convertida.
  EOT com compressão MicroType Express (raro) não é suportado — nesse caso o
  `.eot` original é mantido, com um aviso.
- **contornos TrueType (`glyf`) estáticos** → as curvas quadráticas são convertidas para
  cúbicas (CFF), gerando um OTF de verdade (não é só renomear a extensão).
- **tabelas de layout** (kerning, ligaduras, `GSUB`/`GPOS`) são preservadas.
- **fontes variáveis** (peso/largura/altura) são **preservadas com seus eixos**:
  como o CFF não carrega variações, elas saem como `.ttf` variável (apenas
  descomprimido), ou `.otf` se já forem CFF2. Não são achatadas.
- **tabela `name` compatível com o Font Book da Apple**: fontes web costumam ter
  registros de nome só na plataforma Windows, o que faz o Font Book acusar
  `<no font name>`. A conversão espelha os nomes para as plataformas Windows e
  Macintosh e preenche nomes essenciais que faltarem (usando o `@font-face`).
- **formatos redundantes** da mesma regra `@font-face` (woff2 + woff + ttf do
  mesmo arquivo) são baixados uma vez só, já que todos virariam o mesmo `.otf`.
  Subconjuntos `unicode-range` (regras distintas) são preservados.

Formatos que não dão para converter (`.svg`, ou `.eot` comprimido) são mantidos
como estão.

Ou diretamente (o shebang usa `uv`):

```bash
./fetch-fonts.py https://exemplo.com
```

O caminho de cada fonte salva é impresso em `stdout`; os logs de progresso vão
para `stderr`.
