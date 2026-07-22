#!/usr/bin/env bash
# =============================================================================
# Mede o que realmente importa nesta maquina, em vez de presumir:
#   1. quantas threads valem a pena (geracao satura antes do prompt)
#   2. quanto custa o prompt conforme ele cresce (NAO e linear)
#   3. quanto a geracao desacelera com o KV cache cheio
#
# HISTORICO -- por que este script mudou: a versao anterior comparava "um socket"
# contra "dois sockets" e concluiu que usar os dois derrubava a geracao pela
# metade, atribuindo isso a sincronizacao via UPI. Estava ERRADO. O container LXC
# so enxerga os CPUs 0-19 (todos do mesmo no) e 'numactl --cpunodebind=1' falha
# com "sched_setaffinity: Invalid argument". Aquele teste mediu 40 threads
# disputando 20 CPUs -- oversubscription de 2x --, nao dois sockets. O script
# agora checa quantos CPUs existem de fato e nao mede o que a maquina nao pode
# fazer.
# =============================================================================
set -euo pipefail

PREFIX="${PREFIX:-/opt/llama}"
BENCH="$PREFIX/bin/llama-bench"
MODEL="${1:-}"

[ -x "$BENCH" ] || { echo "llama-bench nao encontrado em $BENCH"; exit 1; }
if [ -z "$MODEL" ]; then
    MODEL=$(ls -S "$PREFIX"/models/*.gguf 2>/dev/null | head -1 || true)
    [ -n "$MODEL" ] || { echo "uso: $0 <modelo.gguf>"; exit 1; }
fi

export LD_LIBRARY_PATH="$PREFIX/lib"

# Quantos CPUs este processo pode MESMO usar. Num LXC isto costuma ser menor que
# o do host, e passar deste numero mede oversubscription, nao paralelismo.
CPUS=$(nproc)
ALLOWED=$(grep -m1 Cpus_allowed_list /proc/self/status 2>/dev/null | cut -f2 || echo "?")
NODES=$(numactl --hardware 2>/dev/null | grep -c '^node [0-9]* size' || echo 1)

echo "======================================================================"
echo " Modelo:   $(basename "$MODEL")  ($(du -h "$MODEL" | cut -f1))"
echo " CPU:      $(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | xargs)"
echo " CPUs usaveis: $CPUS  (lista: $ALLOWED)"
echo " Nos NUMA visiveis: $NODES"
echo "======================================================================"

# Um no NUMA so e utilizavel se der pra prender o processo nele. Num container
# com cpuset restrito, --cpunodebind falha mesmo com o no aparecendo no
# numactl --hardware. Testar de verdade e mais barato que descobrir depois que a
# medicao inteira era invalida.
USABLE_NODES=""
for n in $(seq 0 $((NODES - 1))); do
    if numactl --cpunodebind="$n" --membind="$n" /bin/true 2>/dev/null; then
        USABLE_NODES="$USABLE_NODES $n"
    fi
done
USABLE_NODES="${USABLE_NODES# }"
echo " Nos que aceitam --cpunodebind: ${USABLE_NODES:-nenhum}"
if [ "$(echo "$USABLE_NODES" | wc -w)" -lt 2 ]; then
    echo ""
    echo " NOTA: menos de 2 nos utilizaveis -- a comparacao entre sockets NAO"
    echo "       sera feita, porque este container nao consegue executar nela."
    echo "       Para liberar o outro socket, ajuste os cores do LXC no host."
fi
echo "======================================================================"

# A colocacao das paginas e decidida no PRIMEIRO acesso (first-touch). Se o
# modelo ja estiver no page cache de um teste anterior, o proximo teste herda
# aquela colocacao e o resultado vira lixo. Por isso limpamos entre as rodadas.
drop_cache() { sync; echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true; }

run() {
    local label="$1"; shift
    echo ""
    echo "--- $label ---"
    drop_cache
    # -mmp 0 = --no-mmap: garante alocacao real, sem o page cache decidir por nos
    "$@" -m "$MODEL" -mmp 0 2>/dev/null | grep -E 'model|pp|tg' || echo "  (falhou)"
}

echo ""
echo "### 1) QUANTAS THREADS (geracao satura antes do prompt)"
# Nao passa de $CPUS: alem disso vira oversubscription e o numero nao significa
# nada. Foi assim que a conclusao errada sobre NUMA nasceu.
for t in 10 20; do
    [ "$t" -le "$CPUS" ] || { echo "  (pulando ${t} threads: so ha $CPUS CPUs)"; continue; }
    run "${t} threads" "$BENCH" -t "$t" --numa numactl -p 512 -n 128
done

echo ""
echo "### 2) CUSTO DO PROMPT conforme ele cresce (esperado: NAO linear)"
echo "    A taxa CAI conforme o prompt cresce, porque a atencao e quadratica."
echo "    Divida n_tokens pela taxa para saber a espera pelo 1o token."
run "prefill 512 / 2k / 8k / 32k" "$BENCH" -t 20 --numa numactl -p 512,2048,8192,32768 -n 0 -r 1

echo ""
echo "### 3) GERACAO com o KV cache CHEIO (o que quase ninguem mede)"
echo "    Cada token gerado rele o KV inteiro. Isto mostra o custo real de"
echo "    conversas longas -- na GPU e quase de graca, aqui nao e."
run "geracao a 0 / 4k / 16k / 32k de profundidade" \
    "$BENCH" -t 10 --numa numactl -p 0 -n 64 -d 0,4096,16384,32768 -r 1

echo ""
echo "======================================================================"
echo " Como ler:"
echo "   tg  = geracao (tok/s)  <- o numero que voce sente no dia a dia"
echo "   pp  = leitura do prompt (tok/s) <- define a espera pelo 1o token"
echo ""
echo " Use --threads para o melhor tg e --threads-batch para o melhor pp:"
echo " sao cargas diferentes e o otimo de cada uma nao e o mesmo."
echo "======================================================================"
