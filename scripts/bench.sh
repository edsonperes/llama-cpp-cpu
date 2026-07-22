#!/usr/bin/env bash
# =============================================================================
# Mede o que realmente importa nesta maquina, em vez de presumir:
#   1. tok/s preso em UM socket (memoria 100% local)
#   2. tok/s espalhado nos DOIS sockets (--numa distribute)
#   3. quantas threads valem a pena
#
# Por que isso importa: em dual-socket a geracao pode ESCALAR ou DESPENCAR.
# Medicoes publicas vao de +8% (EPYC Genoa) a -70% (dual Xeon 6980P, que caiu
# de 7.8 para 2-5 tok/s ao usar os dois sockets). A causa nao e banda, e o custo
# de sincronizacao das barreiras entre threads. So medindo pra saber.
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

echo "======================================================================"
echo " Modelo:  $(basename "$MODEL")  ($(du -h "$MODEL" | cut -f1))"
echo " CPU:     $(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | xargs)"
echo " Nos NUMA: $(numactl --hardware | grep -c '^node [0-9]* size')"
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
    "$@" -m "$MODEL" -p 512 -n 128 -mmp 0 2>/dev/null | grep -E 'model|pp512|tg128' || \
        echo "  (falhou)"
}

echo ""
echo "### 1) UM SOCKET (recomendado como padrao)"
for t in 10 20; do
    run "socket 0, ${t} threads" \
        numactl --cpunodebind=0 --membind=0 "$BENCH" -t "$t" --numa numactl
done

echo ""
echo "### 2) DOIS SOCKETS (so vale se ganhar de forma clara)"
for t in 20 40; do
    run "distribute, ${t} threads" "$BENCH" -t "$t" --numa distribute
done

echo ""
echo "======================================================================"
echo " Como ler:"
echo "   tg128 = geracao (tok/s)  <- o numero que voce sente no dia a dia"
echo "   pp512 = leitura do prompt (tok/s) <- define a espera pelo 1o token"
echo ""
echo " Se 'dois sockets' nao ganhar de forma NITIDA do melhor 'um socket',"
echo " fique com um socket: e mais previsivel e libera o outro socket para"
echo " uma segunda instancia independente."
echo "======================================================================"
