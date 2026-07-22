#!/usr/bin/env bash
# =============================================================================
# Baixa modelos GGUF escolhidos para inferencia em CPU.
#
# Criterio de escolha (importante entender antes de trocar por outro):
#  - So MoE. Modelo denso le o arquivo INTEIRO a cada token; um 70B denso da
#    ~1.5 tok/s nesta classe de hardware. MoE le so os experts ativos.
#  - Quants Q4_K / MXFP4. Os IQ* (IQ2/IQ3/IQ4_XS) sao baseados em codebook e
#    NAO tem caminho repack em x86: ~3x mais lento na geracao, ~5x no prefill.
#    Excecao: IQ4_NL (esse tem repack AVX2).
#  - Nada de Q8_0: dobra os bytes lidos num workload ja limitado por banda.
# =============================================================================
set -euo pipefail

MODELS_DIR="${MODELS_DIR:-/opt/llama/models}"

# nome            | repo HF                          | arquivo                                  | GB   | ativos
CATALOG='
qwen3.6-35b|unsloth/Qwen3.6-35B-A3B-GGUF|Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf|22.4|3B
qwen3-30b|unsloth/Qwen3-30B-A3B-GGUF|Qwen3-30B-A3B-UD-Q4_K_XL.gguf|17.7|3.3B
gpt-oss-120b|unsloth/gpt-oss-120b-GGUF|gpt-oss-120b-MXFP4.gguf|62.8|5.1B
'

usage() {
    echo "uso: $0 <nome-do-modelo>"
    echo ""
    echo "disponiveis:"
    printf '%s\n' "$CATALOG" | grep -v '^$' | while IFS='|' read -r n r f gb act; do
        printf "  %-14s %6s GB  %6s ativos  (%s)\n" "$n" "$gb" "$act" "$r"
    done
    echo ""
    echo "recomendado para comecar: qwen3.6-35b"
    exit 1
}

[ $# -eq 1 ] || usage
WANT="$1"

LINE=$(printf '%s\n' "$CATALOG" | grep "^${WANT}|" || true)
[ -n "$LINE" ] || { echo "modelo desconhecido: $WANT"; echo; usage; }

IFS='|' read -r NAME REPO FILE SIZE ACTIVE <<< "$LINE"
DEST="$MODELS_DIR/$FILE"

mkdir -p "$MODELS_DIR"

# ja existe e e um GGUF valido?
if [ -f "$DEST" ] && [ "$(head -c4 "$DEST")" = "GGUF" ]; then
    echo "$FILE ja esta baixado ($(du -h "$DEST" | cut -f1))"
    exit 0
fi

echo "Baixando $NAME  (${SIZE} GB, ${ACTIVE} ativos)"
echo "  de: $REPO"
df -h "$MODELS_DIR" | tail -1 | awk '{print "  espaco livre: " $4}'
echo ""

# -C - permite retomar se cair no meio (util em arquivo de 60 GB)
curl -fL -C - --retry 5 --retry-delay 10 --progress-bar \
    -o "$DEST.part" \
    "https://huggingface.co/$REPO/resolve/main/$FILE"

if [ "$(head -c4 "$DEST.part")" != "GGUF" ]; then
    rm -f "$DEST.part"
    echo "ERRO: o arquivo baixado nao e um GGUF valido" >&2
    exit 1
fi

mv "$DEST.part" "$DEST"
echo ""
echo "OK: $DEST ($(du -h "$DEST" | cut -f1))"
