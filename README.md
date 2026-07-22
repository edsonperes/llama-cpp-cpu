# llama-cpp-cpu

llama.cpp **CPU-only** (AVX-512) para rodar em container LXC no Proxmox, com WebUI
em português e login por usuário/senha.

Feito para servidores **Xeon Scalable sem GPU** — onde a resposta certa não é
"rodar um modelo pequeno", e sim **rodar um MoE grande**.

---

## Por que MoE (e só MoE)

Em CPU, a velocidade de geração é limitada pela **banda de memória**: o que manda
é quantos GB precisam ser lidos a cada token.

| Tipo | Exemplo | GB lidos por token | Velocidade típica |
|---|---|---|---|
| Denso | Llama-70B Q4 (42 GB) | **42 GB** | ~1,5 tok/s ❌ |
| **MoE** | Qwen3.6-35B-A3B Q4 (22 GB) | **~1,9 GB** | **~15-20 tok/s** ✅ |
| **MoE** | gpt-oss-120b MXFP4 (63 GB) | **~2,7 GB** | **~10-14 tok/s** ✅ |

Um MoE de 35B tem capacidade parecida com um denso de 27-32B e roda **6-8× mais
rápido** nesse hardware. Um MoE de 120B — quase 2× maior que o Llama-70B em disco —
roda **~10× mais rápido** que ele. Modelo denso grande é a categoria errada aqui.

---

## Instalação

```bash
git clone https://github.com/edsonperes/llama-cpp-cpu.git
cd llama-cpp-cpu
./scripts/install.sh                    # compila com AVX-512 nativo
./scripts/fetch-model.sh lfm2.5-8b       # baixa o modelo
cp llama.env.example /opt/llama/llama.env
$EDITOR /opt/llama/llama.env            # troque a senha do admin!
cp systemd/*.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now llama-server llama-gateway
```

Acesse `http://IP-DO-CONTAINER:8080` e entre com o usuário/senha do `llama.env`.

---

## Resultados medidos (2x Xeon Gold 6138, 4 canais DDR4-2400)

| Threads | Prompt (pp512) | Geração (tg128) |
|---|---|---|
| **10** | 51,3 | **11,37** |
| 14 | 62,1 | 11,04 |
| 20 | **80,4** | 10,95 |
| 40 (2× os cores disponíveis) | 67,2 | 4,67 |

**Threads separadas.** `--threads 10` para geração (satura a banda de memória
cedo) e `--threads-batch 20` para prompt (escala com cores). É daí que vem a
configuração padrão.

> **Correção.** A linha de 40 threads foi originalmente publicada aqui como
> "2 sockets" com a conclusão de que o custo de sincronização via UPI derrubava a
> geração pela metade. **Isso estava errado.** O container LXC só enxerga os CPUs
> 0-19 — todos do mesmo nó — e `numactl --cpunodebind=1` falha nele com
> `sched_setaffinity: Invalid argument`. Aquele teste nunca usou dois sockets:
> usou 40 threads disputando 20 CPUs, ou seja **oversubscription de 2×**. A queda
> é o efeito esperado disso, e não diz nada sobre NUMA. Prender a um nó continua
> certo — mas por ser o único que o container tem, não por UPI. Usar os dois
> sockets de verdade exigiria reconfigurar os cores do LXC no host Proxmox.

## Contexto: o que custa de verdade

O KV cache é barato: **20.480 bytes/token**, então 64k ocupa 1,34 GB de um limite
de 100 GB. RAM nunca é o fator limitante. O que pesa é tempo:

| Prompt | Espera pelo 1º token | Geração com o KV nesse tamanho |
|---|---|---|
| 8.192 | 2,4 min | 4,75 tok/s (−39%) |
| 32.768 | **12 min** | 2,54 tok/s (−67%) |
| 65.536 | **33 min** | 1,36 tok/s (−82%) |

Duas coisas que a intuição erra:

1. **O prefill não é linear.** A taxa *cai* de 64 para 33 tok/s conforme o prompt
   cresce, porque a atenção é quadrática. Extrapolar linearmente subestima feio.
2. **A geração desacelera com o KV cheio**, não com o `--ctx-size` configurado.
   Cada token gerado relê o cache inteiro. Na GPU isso é quase de graça; aqui
   custa 67% da velocidade em 32k.

Como `--ctx-size` é um **teto** e não um custo fixo, o padrão é generoso (64k):
só pesa o que for realmente preenchido. E há um motivo extra para folga — o
`ctx-shift` está desligado neste modelo (ver abaixo), então estourar o contexto
**falha a requisição** em vez de deslizar a janela.

## Medir na sua máquina

```bash
./scripts/bench.sh
```

Varre contagens de threads e mede prefill e geração em várias profundidades de
KV. **Meça, não presuma** — e confira antes quantos CPUs o container realmente
tem (`nproc`, `grep Cpus_allowed_list /proc/self/status`), porque passar disso
mede oversubscription, não paralelismo.

---

## Armadilhas conhecidas

### Canais de memória (a que mais custa performance)
Xeon Scalable tem **6 canais por socket**. Se os pentes não cobrirem os 6, você
perde banda proporcionalmente — e banda **é** a velocidade aqui.

| DIMMs por socket | Canais ativos | Banda |
|---|---|---|
| 6 | 6/6 | 100% |
| 4 | 4/6 | ~67% |
| 2 | 2/6 | ~33% |

```bash
dmidecode -t memory | grep -E "Locator|Size|Speed"
```
Rearranjar pentes pode render mais tok/s do que qualquer flag.

### Quantização
- ✅ **Q4_K**, **MXFP4** — têm *repack* em runtime (caminho GEMM rápido)
- ✅ **IQ4_NL** — exceção entre os IQ, tem repack AVX2
- ❌ **IQ2/IQ3/IQ4_XS** — baseados em codebook, sem repack em x86:
  **~3× mais lento** na geração, **~5×** no prefill
- ❌ **Q8_0** — dobra os bytes num workload já limitado por banda

> Regra: prefira sempre um modelo **menor em Q4_K** a um **maior em IQ3**.

### Threads
Use os **cores físicos** de um nó, não as threads lógicas. Hyperthreading não
ajuda em carga limitada por memória, e ~12 cores já saturam os canais DDR4.
`THREADS=20` num socket de 20 cores; passar disso não rende.

### KV cache
**Não quantize** (`-ctk/-ctv`) em CPU: o custo de dequantizar a cada passo de
atenção não compensa. Na GPU é quase de graça; aqui não. Deixe `f16`.

### `--cache-reuse` não funciona neste modelo (e não é bug)
O servidor o desliga sozinho no boot:

```
W srv load_model: cache_reuse is not supported by this context, it will be disabled
```

A cadeia, no código do llama.cpp: arch `qwen35`/`qwen35moe` → `LLAMA_ROPE_TYPE_IMROPE`
→ `n_pos_per_embd() == 4` → `get_can_shift() == false` → `n_cache_reuse = 0`.
Contraintuitivamente, **não é a atenção linear** que impede — a memória recorrente
sabe deslocar posições. É o **M-RoPE interleaved**, que usa 4 componentes de
posição por embedding, enquanto o K-shift só lida com uma posição escalar por
célula. Pelo mesmo motivo o `ctx-shift` também fica desligado.

Quem torna o chat incremental barato é o **`--cache-prompt`**, que é default,
funciona em qualquer arquitetura e reaproveita o prefixo comum entre um turno e o
seguinte. Esse está ativo e é o que importa. O `--cache-reuse` seria só um extra
para reaproveitar blocos *depois* de uma divergência no meio do histórico.

### Não use `master` do llama.cpp
`LLAMA_REF` aponta para um **commit fixo**. O upstream reorganiza a WebUI sem
aviso — em 2026-07-07 deletou o `DesktopIconStrip.svelte` e 15 patches nossos
pararam de casar, o que dá **tela branca no login**. Com o commit fixado,
reinstalar reproduz exatamente o que já foi testado. Para atualizar, troque o SHA
e rode o `install.sh`: o `apply.pl` aborta se algum patch falhar, então um SHA
incompatível quebra alto em vez de gerar uma UI quebrada em silêncio.

### O ponto fraco: leitura do prompt
Processar prompt em CPU é **muito** mais lento que em GPU. Um prompt de 16k pode
levar minutos até o primeiro token. Escolher MoE ajuda bastante (só os experts
ativos entram na conta), mas não elimina. Se seu uso manda contexto novo grande a
cada mensagem, considere manter uma GPU para isso.

---

## Arquitetura

```
   :8080  gateway (Go)  ──proxy──>  127.0.0.1:8081  llama-server
           login/senha                              (sem auth própria,
           token por usuário                         só escuta local)
           tool ssh_exec
```

O `llama-server` **nunca** é exposto direto: quem fala com a rede é o gateway,
que faz a autenticação. Usuários e tokens ficam em `/opt/llama/auth/users.json`.

---

## Créditos

WebUI e gateway reaproveitados do projeto irmão
[llama-cpp-casaos](https://github.com/edsonperes/llama-cpp-casaos) (versão CUDA,
para GPU NVIDIA).
