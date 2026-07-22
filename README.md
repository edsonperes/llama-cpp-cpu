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
./scripts/fetch-model.sh qwen3.6-35b    # baixa o modelo
cp llama.env.example /opt/llama/llama.env
$EDITOR /opt/llama/llama.env            # troque a senha do admin!
cp systemd/*.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now llama-server llama-gateway
```

Acesse `http://IP-DO-CONTAINER:8080` e entre com o usuário/senha do `llama.env`.

---

## Medir antes de otimizar

```bash
./scripts/bench.sh
```

Compara **um socket** contra **dois sockets**. Isso não é detalhe: em máquinas de
2 sockets a geração pode escalar (+8%) ou **desabar** (-70%, caso medido num dual
Xeon 6980P que caiu de 7,8 para 2-5 tok/s). O gargalo não é banda, é o custo de
sincronização entre as threads. **Meça, não presuma.**

O padrão do projeto é **um socket** — previsível, e deixa o outro socket livre
para uma segunda instância independente.

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
