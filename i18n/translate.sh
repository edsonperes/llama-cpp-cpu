#!/bin/bash
# translate.sh - Wrapper que chama translate.pl
#
# Uso: translate.sh <webui_src_dir> <translations_file>

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Verifica se perl esta disponivel
if ! command -v perl >/dev/null 2>&1; then
    echo "Erro: perl nao esta instalado. Instale-o antes de continuar."
    exit 1
fi

exec perl "$SCRIPT_DIR/translate.pl" "$@"
