#!/usr/bin/env bash
# =============================================================================
# Instalacao do llama.cpp CPU-only (AVX-512) num LXC Debian 12.
#
# Alvo: Xeon Scalable (Skylake-SP+) com AVX-512, SEM GPU. Pensado para rodar
# modelos MoE, onde so os experts ativos sao lidos por token — o unico jeito
# de LLM grande render em CPU.
#
# Idempotente: pode rodar de novo sem quebrar nada.
# =============================================================================
set -euo pipefail

PREFIX="${PREFIX:-/opt/llama}"
BUILD_DIR="${BUILD_DIR:-/opt/llama/src}"
JOBS="${JOBS:-$(nproc)}"
LLAMA_REF="${LLAMA_REF:-master}"

log() { echo -e "\n\033[1;36m[install]\033[0m $*"; }
die() { echo -e "\n\033[1;31m[erro]\033[0m $*" >&2; exit 1; }

# --- 0) sanidade: a CPU tem mesmo AVX-512? -----------------------------------
log "Verificando CPU..."
if ! grep -qm1 avx512f /proc/cpuinfo; then
    echo "AVISO: esta CPU NAO tem AVX-512. O build ainda funciona (cai para AVX2),"
    echo "       mas a performance sera bem menor que o esperado."
    sleep 3
else
    echo "  AVX-512: OK"
fi
grep -qm1 avx512_vnni /proc/cpuinfo && echo "  AVX512-VNNI: OK (bonus para quantizados)" || true
echo "  cores disponiveis: $(nproc)"
echo "  RAM livre: $(free -g | awk '/^Mem:/{print $7}') GB"

# --- 1) dependencias ---------------------------------------------------------
log "Instalando dependencias..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
    build-essential cmake git curl ca-certificates pkg-config \
    libcurl4-openssl-dev numactl golang-go perl >/dev/null
echo "  ok"

# --- 2) llama.cpp: clonar e compilar ----------------------------------------
log "Obtendo llama.cpp (${LLAMA_REF})..."
mkdir -p "$BUILD_DIR"
if [ -d "$BUILD_DIR/llama.cpp/.git" ]; then
    git -C "$BUILD_DIR/llama.cpp" fetch --depth 1 origin "$LLAMA_REF" -q
    git -C "$BUILD_DIR/llama.cpp" checkout -q FETCH_HEAD
else
    git clone --depth 1 --branch "$LLAMA_REF" -q \
        https://github.com/ggml-org/llama.cpp.git "$BUILD_DIR/llama.cpp"
fi
cd "$BUILD_DIR/llama.cpp"
echo "  commit: $(git rev-parse --short HEAD)"

# --- 3) WebUI: traduzir para PT-BR antes de compilar -------------------------
# O bundle da WebUI e embutido no binario do llama-server, entao as
# customizacoes precisam ser aplicadas ANTES do build.
ASSETS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ -d tools/ui/src ] && [ -f "$ASSETS_DIR/i18n/translate.sh" ]; then
    log "Aplicando WebUI em portugues..."
    [ -f "$ASSETS_DIR/customizations/apply.pl" ] && \
        perl "$ASSETS_DIR/customizations/apply.pl" tools/ui/src || true
    sed -i 's/\r$//' "$ASSETS_DIR/i18n/translate.sh"
    bash "$ASSETS_DIR/i18n/translate.sh" tools/ui/src "$ASSETS_DIR/i18n/pt-br.txt" || true
    if command -v npm >/dev/null 2>&1; then
        (cd tools/ui && npm ci --silent && npm run build --silent) || \
            echo "  aviso: build da WebUI falhou, seguindo com a UI padrao"
    else
        echo "  aviso: npm nao encontrado, WebUI ficara em ingles"
        echo "         (instale Node 20+ e rode de novo se quiser PT-BR)"
    fi
fi

# --- 4) compilar ------------------------------------------------------------
# GGML_NATIVE=ON  -> usa -march=native, habilita AVX-512 desta CPU
# GGML_CUDA=OFF   -> CPU-only, sem dependencia de driver NVIDIA
log "Compilando (${JOBS} jobs)... isso leva alguns minutos"
cmake -B build \
    -DCMAKE_BUILD_TYPE=Release \
    -DGGML_NATIVE=ON \
    -DGGML_CUDA=OFF \
    -DGGML_BLAS=OFF \
    -DLLAMA_CURL=ON \
    -DLLAMA_BUILD_TESTS=OFF \
    -DLLAMA_BUILD_EXAMPLES=OFF \
    >/dev/null
cmake --build build --config Release -j"$JOBS" >/dev/null
echo "  compilado"

# --- 5) instalar binarios ---------------------------------------------------
# ATENCAO: a WebUI NAO fica no binario llama-server (que tem ~8KB e e so um
# wrapper) — ela e compilada dentro de libllama-server-impl.so. Por isso o build
# acima nao pode usar --target llama-server: se so esse target for reconstruido,
# a lib com a UI continua velha e o servidor segue servindo o bundle antigo.
# Sempre rebuilde tudo e recopie TODAS as libs junto com o binario.
log "Instalando em ${PREFIX}..."
mkdir -p "$PREFIX/bin" "$PREFIX/lib" "$PREFIX/models" "$PREFIX/auth"
for b in llama-server llama-bench llama-cli; do
    [ -f "build/bin/$b" ] && install -m755 "build/bin/$b" "$PREFIX/bin/$b"
done
find build -name '*.so*' -exec cp -P {} "$PREFIX/lib/" \; 2>/dev/null || true
echo "  binarios: $(ls "$PREFIX/bin" | tr '\n' ' ')"

# --- 6) gateway de login (Go) -----------------------------------------------
if [ -f "$ASSETS_DIR/gateway/main.go" ]; then
    log "Compilando o gateway de login..."
    (cd "$ASSETS_DIR/gateway" && CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" \
        -o "$PREFIX/bin/gateway" .)
    echo "  ok"
fi

# --- 7) confirmar que o AVX-512 foi mesmo compilado -------------------------
log "Verificando o binario..."
if "$PREFIX/bin/llama-server" --version 2>&1 | head -5; then :; fi

log "Instalacao concluida."
echo ""
echo "  Proximo passo: baixar um modelo e subir o servico"
echo "    $PREFIX/bin/../scripts/fetch-model.sh qwen3.6-35b"
echo "    systemctl enable --now llama-server"
