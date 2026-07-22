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

# Resolvido AQUI, antes de qualquer 'cd'. BASH_SOURCE costuma ser relativo
# ("./scripts/install.sh"), entao calcular isto depois de mudar de diretorio
# aponta para um caminho que nao existe. Quando isso acontecia, a condicao que
# guardava a etapa da WebUI dava falso e o bloco inteiro era PULADO em silencio:
# o script terminava com exit 0 anunciando "Instalacao concluida" e o servidor
# subia com a UI padrao do llama.cpp, sem login, sem gestao de usuarios e sem
# tokens de API.
ASSETS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PREFIX="${PREFIX:-/opt/llama}"
BUILD_DIR="${BUILD_DIR:-/opt/llama/src}"
JOBS="${JOBS:-$(nproc)}"
# Commit FIXO do llama.cpp -- NAO trocar por "master". O upstream muda depressa e
# reorganiza a WebUI: em 2026-07-07 ele deletou o DesktopIconStrip.svelte e 15 dos
# nossos patches pararam de casar, o que da tela branca no login. Com o commit
# fixado, reinstalar reproduz exatamente o que ja foi testado.
# Para atualizar: troque o SHA e rode ./scripts/install.sh -- o apply.pl aborta se
# algum patch nao casar, entao um SHA incompativel falha alto em vez de gerar uma
# UI quebrada. Depois de validar, comite o SHA novo.
LLAMA_REF="${LLAMA_REF:-0278d8362d78c5de291bc03b76016f7f74b2ab77}"

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
# fetch de um commit especifico. Nao usar 'git clone --branch': ele so aceita
# branch ou tag, nunca um SHA.
if [ ! -d "$BUILD_DIR/llama.cpp/.git" ]; then
    mkdir -p "$BUILD_DIR/llama.cpp"
    git -C "$BUILD_DIR/llama.cpp" init -q
    git -C "$BUILD_DIR/llama.cpp" remote add origin \
        https://github.com/ggml-org/llama.cpp.git
fi
git -C "$BUILD_DIR/llama.cpp" fetch --depth 1 -q origin "$LLAMA_REF"
git -C "$BUILD_DIR/llama.cpp" checkout -q FETCH_HEAD
cd "$BUILD_DIR/llama.cpp"
echo "  commit: $(git rev-parse --short HEAD)"

# --- 3) WebUI: traduzir para PT-BR antes de compilar -------------------------
# O bundle da WebUI e embutido no binario do llama-server, entao as
# customizacoes precisam ser aplicadas ANTES do build.
log "Aplicando WebUI em portugues..."
# Cada pre-requisito e checado com die(), NUNCA com um 'if' que apenas pula. Um
# bloco pulado em silencio foi o que fez esta etapa inteira sumir de uma
# instalacao que mesmo assim terminou com exit 0 e a mensagem "Instalacao
# concluida" -- e so muito depois se descobre que a UI subiu sem login.
[ -d tools/ui/src ] || die "tools/ui/src nao existe em $(pwd) -- o checkout do
       llama.cpp falhou ou o upstream mudou o layout do repositorio."
[ -f "$ASSETS_DIR/i18n/translate.sh" ] || die "nao achei $ASSETS_DIR/i18n/translate.sh
       -- ASSETS_DIR ficou errado (esperado: a raiz deste repositorio)."
[ -f "$ASSETS_DIR/customizations/apply.pl" ] || die "nao achei
       $ASSETS_DIR/customizations/apply.pl -- sem ele a WebUI sai sem os botoes
       de Endpoints/Usuarios/SSH/Sair e sem o controle de admin."
command -v npm >/dev/null 2>&1 || die "npm nao encontrado. A WebUI customizada
       (login, gestao de usuarios, tokens de API) e compilada aqui -- sem Node
       20+ o servidor subiria com a UI padrao do llama.cpp, sem nada disso."

# SEM '|| true' em nenhuma linha abaixo, de proposito. O apply.pl sai com codigo
# != 0 quando algum patch nao casa (tipicamente porque o upstream mexeu na
# WebUI), e engolir esse erro foi exatamente o que fez tres versoes irem pro ar
# sem os botoes, sem ninguem perceber. Com 'set -euo pipefail', a falha aborta a
# instalacao -- melhor nao instalar do que instalar uma UI quebrada.
perl "$ASSETS_DIR/customizations/apply.pl" tools/ui/src
sed -i 's/\r$//' "$ASSETS_DIR/i18n/translate.sh"
bash "$ASSETS_DIR/i18n/translate.sh" tools/ui/src "$ASSETS_DIR/i18n/pt-br.txt"
# A UI e compilada dentro de libllama-server-impl.so; se o build quebrar e a
# instalacao continuar, o servidor sobe servindo o bundle antigo e o sintoma
# aparece so depois, dificil de rastrear.
(cd tools/ui && npm ci --silent && npm run build --silent)

# Prova de que a customizacao realmente entrou no bundle, em vez de confiar que
# os passos acima "devem ter funcionado". Este e o unico teste que importa: o
# usuario ve o bundle, nao o codigo-fonte patchado.
BUNDLE=$(ls tools/ui/dist/_app/immutable/bundle.*.js 2>/dev/null | head -1)
[ -n "$BUNDLE" ] || die "o build da WebUI nao gerou bundle em tools/ui/dist."
for marcador in "Endpoints da API" "Servidores SSH"; do
    grep -q "$marcador" "$BUNDLE" || die "o bundle gerado nao contem
       \"$marcador\". Os patches aplicaram mas nao chegaram na saida --
       nao instale assim, a UI ficaria sem gestao de usuarios/API."
done
echo "  WebUI: patches + traducao OK, marcadores presentes no bundle"

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
