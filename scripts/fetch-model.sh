#!/usr/bin/env bash
# =============================================================================
# Baixa modelos GGUF escolhidos para inferencia em CPU.
#
# Criterio de escolha (importante entender antes de trocar por outro):
#  - O que decide a velocidade e PARAMETROS ATIVOS, nao o tamanho do arquivo:
#        tok/s ~= banda_de_memoria / GB_lidos_por_token
#    Por isso "modelo maior" costuma ser mais LENTO aqui, e um MoE de 8B com 1B
#    ativo ganha facil de um denso de 4B (que le tudo a cada token).
#  - Quants Q4_K / MXFP4. Os IQ* (IQ2/IQ3/IQ4_XS) sao baseados em codebook e
#    NAO tem caminho repack em x86: ~3x mais lento na geracao, ~5x no prefill.
#    Excecao: IQ4_NL (esse tem repack AVX2).
#  - Nada de Q8_0: dobra os bytes lidos num workload ja limitado por banda.
#    Medido: Agents-A1-4B em Q8_0 ficou MAIS LENTO que um MoE de 35B.
#  - Tool calling precisa de parser no llama.cpp. Formatos com handler dedicado
#    (LFM2, GPT-OSS, Gemma4, Kimi K2, Ministral...) sao mais confiaveis que os
#    que dependem do autoparser generico. Pontuacao alta em BFCL nao basta.
#
# MEDIDO neste hardware (2x Xeon Gold 6138, 20 cores utilizaveis, sem GPU),
# mesmo llama-bench para todos, tool calling verificado de verdade em cada um:
#
#   modelo                    ativos   geracao      prefill    arquivo
#   LFM2.5-8B-A1B              1B      42,6 tok/s   148,6      4,8 GB  <-- padrao
#   Gemma 4 E2B QAT           ~2B      25,1         121,1      3,1 GB
#   Agents-A1-4B Q4_K_M        4B*     13,8          72,0      2,7 GB  (*denso)
#   Qwen3.6-35B-A3B            3B      11,0          50,0     20,8 GB
#
# gpt-oss-120b foi descartado sem baixar: 5,1B ativos dariam ~4 tok/s, abaixo do
# piso utilizavel para agente (que encadeia varias chamadas por resposta).
# =============================================================================
set -euo pipefail

MODELS_DIR="${MODELS_DIR:-/opt/llama/models}"

# nome            | repo HF                          | arquivo                                  | GB   | ativos
CATALOG='
lfm2.5-8b|LiquidAI/LFM2.5-8B-A1B-GGUF|LFM2.5-8B-A1B-Q4_K_M.gguf|4.8|1B
gemma4-e2b|google/gemma-4-E2B-it-qat-q4_0-gguf|gemma-4-E2B_q4_0-it.gguf|3.1|~2B
qwen3.6-35b|unsloth/Qwen3.6-35B-A3B-GGUF|Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf|22.4|3B
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
    echo "recomendado: lfm2.5-8b (o mais rapido medido aqui, com tool calling verificado)"
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
