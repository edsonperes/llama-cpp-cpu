#!/usr/bin/perl
# customizations/apply.pl
# Aplica customizacoes da WebUI do llama.cpp
#
# Uso: apply.pl <webui_src_dir>
#
# Customizacoes:
#   1. CodeBlockActions aceita SVG e auto-detecta HTML/SVG
#   2. DialogCodePreview vira painel lateral (50% direito, nao fullscreen)
#   3. Chat reduz pra metade esquerda quando preview esta aberto
#   4. SVG renderiza com wrapping HTML
#   5. Iframe debouncia updates pra evitar flicker durante streaming
#   6. MarkdownContent abre preview automaticamente quando modelo gera HTML/SVG
#      (live preview durante streaming)

use strict;
use warnings;
use utf8;
use open ':std', ':utf8';

my $webui_src = $ARGV[0] // die "Uso: $0 <webui_src_dir>\n";
die "Diretorio nao existe: $webui_src\n" unless -d $webui_src;

print "Aplicando customizacoes em $webui_src\n";

# ---------------------------------------------------------------------------
# Contadores globais.
#
# Historico: ate 2026-07 um patch que nao casava so emitia warn e o build
# seguia, publicando uma imagem degradada sem ninguem perceber (aconteceu nas
# 1.0.19/1.0.20/1.0.21, com 15 patches quebrados por duas semanas). Agora o
# script conta as falhas e sai com codigo != 0 no fim, quebrando o docker
# build em vez de publicar lixo.
#
# Um patch legitimamente opcional deve ser marcado passando OPTIONAL como 5o
# argumento de patch_file(). Ele avisa mas NAO entra na conta de falhas.
# O default e CRITICO.
# ---------------------------------------------------------------------------
use constant OPTIONAL => 1;

my $applied = 0;
my $failed  = 0;
my @failures;
my @skipped_optional;

sub patch_file {
    my ($file, $pattern, $replacement, $description, $optional) = @_;

    my $fail = sub {
        my ($reason) = @_;
        if ($optional) {
            warn "  ~ $description: $reason (OPCIONAL, ignorado)\n";
            push @skipped_optional, $description;
        } else {
            warn "  ! $description: $reason\n";
            $failed++;
            push @failures, $description;
        }
        return 0;
    };

    unless (-f $file) {
        return $fail->("arquivo nao encontrado $file");
    }
    open(my $in, '<:encoding(UTF-8)', $file) or die "Cannot read $file: $!";
    local $/;
    my $content = <$in>;
    close $in;

    my $original = $content;
    if (ref($replacement) eq 'CODE') {
        $content =~ s/$pattern/$replacement->()/ge;
    } else {
        $content =~ s/$pattern/$replacement/g;
    }

    if ($content ne $original) {
        open(my $out, '>:encoding(UTF-8)', $file) or die "Cannot write $file: $!";
        print $out $content;
        close $out;
        print "  + $description\n";
        $applied++;
        return 1;
    }

    return $fail->("padrao nao encontrado em $file");
}

# Cria (ou sobrescreve) um arquivo novo
sub write_file {
    my ($file, $content, $description) = @_;
    open(my $out, '>:encoding(UTF-8)', $file) or die "Cannot write $file: $!";
    print $out $content;
    close $out;
    print "  + $description\n";
    $applied++;
    return 1;
}

# ===========================================================================
# Preview de codigo: aceita SVG, auto-deteccao, painel lateral, live update
# ===========================================================================

print "\n[1] Preview de codigo - aceita SVG e auto-deteccao...\n";

my $code_block_actions = "$webui_src/lib/components/app/misc/CodeBlockActions.svelte";
patch_file(
    $code_block_actions,
    qr/const showPreview = \$derived\(language\?\.toLowerCase\(\) === FileTypeText\.HTML\);/,
    q{const showPreview = $derived((() => {
		const lang = (language || '').toLowerCase();
		if (lang === 'html' || lang === 'svg') return true;
		if ((lang === 'xml' || lang === '') && /<svg[\s>]/i.test(code)) return true;
		if (lang === '' && /<!doctype\s+html|<html[\s>]/i.test(code)) return true;
		return false;
	})());},
    "CodeBlockActions: preview aceita SVG e auto-deteccao"
);

print "\n[2] DialogCodePreview - painel lateral nao-modal...\n";

my $dialog_code_preview = "$webui_src/lib/components/app/dialogs/DialogCodePreview.svelte";

# 2.1: Variaveis pra throttle + estado iframe loaded
patch_file(
    $dialog_code_preview,
    qr/let iframeRef = \$state<HTMLIFrameElement \| null>\(null\);/,
    q{let iframeRef = $state<HTMLIFrameElement | null>(null);
	let pendingTimer: ReturnType<typeof setTimeout> | null = null;
	let lastRenderedCode = '';
	let lastRenderAt = 0;
	let iframeLoaded = $state(false);},
    "DialogCodePreview: variaveis de throttle"
);

# 2.2: Effect com THROTTLE (nao debounce) - garante updates durante streaming
# E adiciona/remove classe code-preview-open no <html> raiz
patch_file(
    $dialog_code_preview,
    qr/\$effect\(\(\) => \{\s*if \(!iframeRef\) return;\s*if \(open\) \{\s*iframeRef\.srcdoc = code;\s*\} else \{\s*iframeRef\.srcdoc = '';\s*\}\s*\}\);/s,
    q{function buildSrcdoc(rawCode: string, rawLang: string): string {
		const lang = (rawLang || '').toLowerCase();
		if (lang === 'svg' || (lang === 'xml' && /<svg[\s>]/i.test(rawCode))) {
			return '<!DOCTYPE html><html><head><style>html,body{margin:0;padding:0;display:flex;align-items:center;justify-content:center;min-height:100vh;background:#fff}svg{max-width:100%;max-height:100vh}</style></head><body>' + rawCode + '</body></html>';
		}
		return rawCode;
	}

	function performRender() {
		if (!iframeRef || !open) return;
		if (code === lastRenderedCode) return;
		iframeRef.srcdoc = buildSrcdoc(code, language);
		lastRenderedCode = code;
		lastRenderAt = (typeof performance !== 'undefined' ? performance.now() : Date.now());
	}

	$effect(() => {
		if (!iframeRef) return;
		if (!open) {
			if (pendingTimer) { clearTimeout(pendingTimer); pendingTimer = null; }
			iframeRef.srcdoc = '';
			lastRenderedCode = '';
			lastRenderAt = 0;
			iframeLoaded = false;
			if (typeof document !== 'undefined') {
				document.documentElement.classList.remove('code-preview-open');
			}
			return;
		}
		if (typeof document !== 'undefined') {
			document.documentElement.classList.add('code-preview-open');
		}
		// Touch reactivity
		const _touch = code;
		if (code === lastRenderedCode) return;

		const THROTTLE_MS = 200;
		const now = (typeof performance !== 'undefined' ? performance.now() : Date.now());
		const elapsed = now - lastRenderAt;

		if (lastRenderAt === 0 || elapsed >= THROTTLE_MS) {
			// Primeira renderizacao ou tempo suficiente passou: renderiza ja
			if (pendingTimer) { clearTimeout(pendingTimer); pendingTimer = null; }
			performRender();
		} else if (!pendingTimer) {
			// Throttle ativo: agenda renderizacao pro fim do periodo
			pendingTimer = setTimeout(() => {
				pendingTimer = null;
				performRender();
			}, THROTTLE_MS - elapsed);
		}
	});

	function handleIframeLoad() {
		iframeLoaded = true;
	}},
    "DialogCodePreview: throttle 200ms + iframe loaded state"
);

# 2.3: Dialog em modo nao-modal
patch_file(
    $dialog_code_preview,
    qr/<DialogPrimitive\.Root \{open\} onOpenChange=\{handleOpenChange\}>/,
    "<DialogPrimitive.Root {open} onOpenChange={handleOpenChange} modal={false}>",
    "DialogCodePreview: nao-modal"
);

# 2.3b: Impede que clicar fora ou Esc fechem o preview E desativa o focus trap.
# - interactOutsideBehavior/escapeKeydownBehavior=ignore: nao fecha em clique
#   fora nem Esc (so o X fecha)
# - trapFocus=false: CRUCIAL. Sem isso o bits-ui prende o foco dentro do dialog
#   e devolve o foco pro botao X toda vez que voce tenta focar o textarea do
#   chat. Resultado: clicar funciona mas digitar nao. Confirmado no navegador.
# - preventScroll/onOpenAutoFocus: evita roubar foco ao abrir
patch_file(
    $dialog_code_preview,
    qr/<DialogPrimitive\.Content class="code-preview-content">/,
    "<DialogPrimitive.Content class=\"code-preview-content\" interactOutsideBehavior=\"ignore\" escapeKeydownBehavior=\"ignore\" trapFocus={false} onOpenAutoFocus={(e) => e.preventDefault()} onCloseAutoFocus={(e) => e.preventDefault()}>",
    "DialogCodePreview: ignora interacao, sem focus trap"
);

# 2.4: CSS - overlay nao bloqueia chat
# IMPORTANTE: o bits-ui aplica "pointer-events: auto" INLINE no overlay,
# o que sobrescreve regra CSS normal. Precisa de !important pra forcar none,
# senao o overlay invisivel (que cobre a tela toda) captura todos os cliques
# do chat. Confirmado via teste no navegador.
patch_file(
    $dialog_code_preview,
    qr/:global\(\.code-preview-overlay\) \{[^}]+\}/s,
    q{:global(.code-preview-overlay) {
			position: fixed;
			inset: 0;
			background-color: transparent;
			pointer-events: none !important;
			z-index: 50;
		}},
    "DialogCodePreview: overlay pointer-events none !important"
);

# 2.5: CSS - painel lateral 50% direita
patch_file(
    $dialog_code_preview,
    qr/:global\(\.code-preview-content\) \{[^}]+\}/s,
    q{:global(.code-preview-content) {
			position: fixed;
			top: 0;
			right: 0;
			bottom: 0;
			left: auto;
			width: 50vw;
			max-width: 50vw;
			height: 100dvh;
			margin: 0;
			padding: 0;
			border: none;
			border-left: 1px solid hsl(var(--border));
			border-radius: 0;
			background-color: hsl(var(--background));
			box-shadow: -4px 0 16px rgba(0,0,0,0.15);
			display: flex;
			flex-direction: column;
			overflow: hidden;
			transform: none !important;
			z-index: 60;
			pointer-events: auto;
		}
		@media (max-width: 767px) {
			:global(.code-preview-content) {
				width: 100vw;
				max-width: 100vw;
				border-left: none;
			}
		}
		/* Quando preview esta aberto, encolhe o body pra metade esquerda */
		/* Elementos fixed do preview ficam fora do flow, nao sao afetados */
		:global(html.code-preview-open) {
			--preview-width: 50vw;
		}
		:global(html.code-preview-open body) {
			max-width: calc(100vw - var(--preview-width, 50vw));
			overflow-x: hidden;
		}
		@media (max-width: 767px) {
			:global(html.code-preview-open body) {
				max-width: 100vw;
			}
		}
		/* O bits-ui aplica inline pointer-events:none no body quando o dialog
		   abre, travando os cliques no chat. Sobrescreve com !important.
		   Duas regras (classe + :has) pra cobrir qualquer timing. */
		:global(html.code-preview-open body) {
			pointer-events: auto !important;
		}
		:global(body:has(.code-preview-content)) {
			pointer-events: auto !important;
		}},
    "DialogCodePreview: painel lateral + encolhe chat + body clicavel"
);

# 2.6: CSS - iframe ocupa 100% do painel
patch_file(
    $dialog_code_preview,
    qr/:global\(\.code-preview-iframe\) \{[^}]+\}/s,
    q{:global(.code-preview-iframe) {
			display: block;
			flex: 1;
			width: 100%;
			height: 100%;
			border: 0;
			background: white;
		}},
    "DialogCodePreview: iframe ocupa 100%"
);

# 2.7: Botao fechar visivel (sem mix-blend-difference)
patch_file(
    $dialog_code_preview,
    qr/class="code-preview-close absolute top-4 right-4 border-none bg-transparent text-white opacity-70 mix-blend-difference transition-opacity hover:opacity-100[^"]*"/s,
    q{class="code-preview-close absolute top-3 right-3 z-10 flex h-9 w-9 items-center justify-center rounded-full border bg-background text-foreground opacity-90 shadow-sm transition-all hover:opacity-100 hover:scale-105 focus-visible:ring-2 focus-visible:ring-ring focus-visible:outline-none disabled:pointer-events-none [&_svg]:size-5"},
    "DialogCodePreview: botao fechar visivel"
);

# 2.8: Adiciona estado derivado hasVisibleContent + overlay
patch_file(
    $dialog_code_preview,
    qr/function handleIframeLoad\(\) \{\s*iframeLoaded = true;\s*\}/s,
    q{function handleIframeLoad() {
		iframeLoaded = true;
	}

	// Heuristica: tem conteudo visivel quando body/svg tem qualquer conteudo
	// ou o codigo tem tamanho razoavel
	const hasVisibleContent = $derived((() => {
		const c = code || '';
		if (!c.trim()) return false;
		// body com qualquer conteudo nao-whitespace dentro
		if (/<body[^>]*>[\s\S]*?\S/i.test(c)) return true;
		// svg com qualquer conteudo
		if (/<svg[^>]*>[\s\S]*?\S/i.test(c)) return true;
		// codigo razoavelmente grande (provavelmente tem algo pra mostrar)
		if (c.trim().length > 80) return true;
		return false;
	})());},
    "DialogCodePreview: derived hasVisibleContent"
);

# 2.8b: Substitui iframe com overlay (multi-linha)
patch_file(
    $dialog_code_preview,
    qr{<iframe\s+bind:this=\{iframeRef\}\s+title="Preview \{language\}"\s+sandbox="allow-scripts"\s+class="code-preview-iframe"\s*></iframe>}s,
    q{<div class="code-preview-building" class:hidden={hasVisibleContent}>
				<div class="code-preview-building-inner">
					<div class="code-preview-spinner"></div>
					<p class="code-preview-building-text">Construindo página...</p>
					<p class="code-preview-building-hint">A pré-visualização aparecerá enquanto o modelo gera o código.</p>
				</div>
			</div>
			<iframe
				bind:this={iframeRef}
				title="Preview {language}"
				sandbox="allow-scripts"
				class="code-preview-iframe"
				onload={handleIframeLoad}
			></iframe>},
    "DialogCodePreview: overlay com heuristica hasVisibleContent"
);

# 2.9: CSS do overlay (PRETO de base + overlay ACIMA do iframe)
patch_file(
    $dialog_code_preview,
    qr/:global\(\.code-preview-iframe\) \{[^}]+\}/s,
    q{:global(.code-preview-iframe) {
			display: block;
			flex: 1;
			width: 100%;
			height: 100%;
			border: 0;
			background: transparent;
			position: absolute;
			inset: 0;
			z-index: 1;
		}
		/* Painel inteiro com fundo preto de base */
		:global(.code-preview-content) {
			background-color: #0a0a0a !important;
		}
		:global(.code-preview-building) {
			position: absolute;
			inset: 0;
			z-index: 2;
			display: flex;
			align-items: center;
			justify-content: center;
			background: #0a0a0a;
			color: rgba(255, 255, 255, 0.9);
			pointer-events: none;
			transition: opacity 0.4s ease, visibility 0.4s ease;
			visibility: visible;
			opacity: 1;
		}
		:global(.code-preview-building.hidden) {
			opacity: 0;
			visibility: hidden;
		}
		:global(.code-preview-building-inner) {
			text-align: center;
			padding: 24px;
			max-width: 400px;
		}
		:global(.code-preview-spinner) {
			width: 48px;
			height: 48px;
			border: 4px solid rgba(255, 255, 255, 0.1);
			border-top-color: rgba(255, 255, 255, 0.85);
			border-radius: 50%;
			margin: 0 auto 16px;
			animation: code-preview-spin 0.9s linear infinite;
		}
		:global(.code-preview-building-text) {
			margin: 0;
			font-size: 18px;
			font-weight: 600;
			letter-spacing: 0.02em;
		}
		:global(.code-preview-building-hint) {
			margin: 8px 0 0 0;
			font-size: 13px;
			opacity: 0.6;
		}
		@keyframes code-preview-spin {
			to { transform: rotate(360deg); }
		}},
    "DialogCodePreview: CSS overlay ACIMA + fundo preto base"
);

# ===========================================================================
# Auto-preview durante streaming
# ===========================================================================

print "\n[3] Auto-preview durante streaming...\n";

my $markdown_content = "$webui_src/lib/components/app/content/MarkdownContent/MarkdownContent.svelte";

# 3.0: Criar o store coordenador global (garante 1 preview aberto por vez)
my $coordinator_store = "$webui_src/lib/stores/preview-coordinator.svelte.ts";
write_file($coordinator_store, <<'TS', "criado preview-coordinator.svelte.ts");
// Coordena o painel de preview entre todas as mensagens do chat.
// Cada MarkdownContent tem seu proprio DialogCodePreview; sem isso, pedir
// uma modificacao abriria um segundo preview por cima do anterior.
// Mantemos um unico "dono" ativo: quando uma mensagem reivindica o preview,
// as outras fecham o seu.
//
// lastHtmlBase: guarda o ultimo bloco HTML completo que foi previewado.
// Usado quando uma modificacao gera APENAS um bloco CSS/JS numa nova
// mensagem (sem reescrever o HTML) - aih combinamos o HTML anterior com
// o novo CSS/JS pra que o preview reflita o ajuste.
let activeId = $state<string | null>(null);
let lastHtmlBase = $state('');
// Sinal incrementado quando algo (navegacao, clique no menu lateral) pede
// pra fechar o preview. Cada MarkdownContent observa e fecha o seu.
let closeSignal = $state(0);

export const previewCoordinator = {
	get activeId() {
		return activeId;
	},
	get lastHtmlBase() {
		return lastHtmlBase;
	},
	get closeSignal() {
		return closeSignal;
	},
	setHtmlBase(html: string) {
		if (html) lastHtmlBase = html;
	},
	requestCloseAll() {
		closeSignal++;
	},
	claim(id: string) {
		activeId = id;
	},
	release(id: string) {
		if (activeId === id) {
			activeId = null;
		}
	}
};
TS

# 3.0b: Importar o coordenador + beforeNavigate no MarkdownContent
patch_file(
    $markdown_content,
    qr/(import \{ config \} from '\$lib\/stores\/settings\.svelte';)/,
    sub { "$1\n\timport { previewCoordinator } from '\$lib/stores/preview-coordinator.svelte';\n\timport { beforeNavigate } from '\$app/navigation';" },
    "MarkdownContent: importa previewCoordinator + beforeNavigate"
);

# 3.0c: Adiciona instanceId + flag + effects de coordenacao + fechar ao navegar
patch_file(
    $markdown_content,
    qr/(let previewLanguage = \$state\('text'\);)/,
    sub { "$1\n\t// Auto-preview: flag pra nao reabrir se usuario fechou durante stream\n\tlet autoPreviewClosedByUser = \$state(false);\n\t// ID unico desta instancia, pra coordenar qual preview fica aberto\n\tconst previewInstanceId = (typeof crypto !== 'undefined' && crypto.randomUUID) ? crypto.randomUUID() : 'pv-' + Math.floor(Math.random() * 1e9);\n\t// Quando ESTE preview abre, reivindica a posse global\n\t\$effect(() => {\n\t\tif (previewDialogOpen) {\n\t\t\tpreviewCoordinator.claim(previewInstanceId);\n\t\t}\n\t});\n\t// Quando OUTRO preview reivindica, fecha este (sem fechar o painel do outro)\n\t\$effect(() => {\n\t\tif (previewDialogOpen && previewCoordinator.activeId !== null && previewCoordinator.activeId !== previewInstanceId) {\n\t\t\tpreviewDialogOpen = false;\n\t\t\tpreviewCode = '';\n\t\t\tpreviewLanguage = 'text';\n\t\t}\n\t});\n\t// Fecha o preview quando recebe o sinal global (clique no menu lateral)\n\tlet lastSeenCloseSignal = 0;\n\t\$effect(() => {\n\t\tconst sig = previewCoordinator.closeSignal;\n\t\tif (sig !== lastSeenCloseSignal) {\n\t\t\tlastSeenCloseSignal = sig;\n\t\t\tif (previewDialogOpen) {\n\t\t\t\tpreviewDialogOpen = false;\n\t\t\t\tpreviewCode = '';\n\t\t\t\tpreviewLanguage = 'text';\n\t\t\t\tpreviewCoordinator.release(previewInstanceId);\n\t\t\t}\n\t\t}\n\t});\n\t// Antes de qualquer navegacao (nova conversa, MCP, settings, trocar conversa),\n\t// pede pra fechar o preview\n\tbeforeNavigate(() => {\n\t\tpreviewCoordinator.requestCloseAll();\n\t});" },
    "MarkdownContent: instanceId + coordenacao + fechar ao navegar"
);

# 3.0d: Libera a posse quando o usuario fecha o preview pelo X
patch_file(
    $markdown_content,
    qr/(function handlePreviewDialogOpenChange\(open: boolean\) \{\s*previewDialogOpen = open;\s*if \(!open\) \{\s*previewCode = '';\s*previewLanguage = 'text';)/s,
    sub { "$1\n\t\t\tpreviewCoordinator.release(previewInstanceId);" },
    "MarkdownContent: release no close"
);

patch_file(
    $markdown_content,
    qr/(let previousContent = '';\s*\n)/,
    sub {
        my $prefix = $1;
        return $prefix . q{
	// Combina HTML com blocos CSS/JS irmaos na mesma mensagem.
	// Sempre retorna pelo menos baseHtml em caso de erro.
	function combineHtmlWithSiblings(fullContent: string, baseHtml: string, incomplete: { language: string | null; code: string } | null): string {
		try {
			if (!baseHtml || typeof baseHtml !== 'string') return baseHtml || '';
			if (!fullContent || typeof fullContent !== 'string') return baseHtml;

			let css = '';
			let js = '';
			const blockRegex = /```(\w+)?\n([\s\S]*?)```/g;
			let m;
			while ((m = blockRegex.exec(fullContent)) !== null) {
				const lang = (m[1] || '').toLowerCase();
				if (lang === 'css') css += m[2] + '\n';
				else if (lang === 'js' || lang === 'javascript') js += m[2] + '\n';
			}
			if (incomplete && incomplete.language) {
				const lang = incomplete.language.toLowerCase();
				if (lang === 'css') css += (incomplete.code || '') + '\n';
				else if (lang === 'js' || lang === 'javascript') js += (incomplete.code || '') + '\n';
			}
			if (!css.trim() && !js.trim()) return baseHtml;

			// Construir tags sem que o parser Svelte veja literais
			const SCR_OPEN = '<' + 'script>';
			const SCR_CLOSE = '<' + '/script>';
			const STY_OPEN = '<' + 'style>';
			const STY_CLOSE = '<' + '/style>';
			const styleTag = css.trim() ? (STY_OPEN + '\n' + css + STY_CLOSE) : '';
			const scriptTag = js.trim() ? (SCR_OPEN + '\n' + js + SCR_CLOSE) : '';

			let combined = baseHtml;
			// Injetar style apos <head> ou no inicio
			if (styleTag) {
				const headOpen = /<head[^>]*>/i.exec(combined);
				if (headOpen) {
					const pos = headOpen.index + headOpen[0].length;
					combined = combined.slice(0, pos) + '\n' + styleTag + combined.slice(pos);
				} else {
					combined = styleTag + '\n' + combined;
				}
			}
			// Injetar script antes de </body> ou no fim
			if (scriptTag) {
				const bodyClose = /<\/body>/i.exec(combined);
				if (bodyClose) {
					combined = combined.slice(0, bodyClose.index) + scriptTag + '\n' + combined.slice(bodyClose.index);
				} else {
					combined = combined + '\n' + scriptTag;
				}
			}
			return combined;
		} catch (e) {
			if (typeof console !== 'undefined') console.error('[preview] combineHtmlWithSiblings error', e);
			return baseHtml;
		}
	}

	// Extrai o ultimo bloco HTML completo da mensagem
	function extractLastHtmlBlock(fullContent: string): string {
		try {
			if (!fullContent || typeof fullContent !== 'string') return '';
			const blockRegex = /```(\w+)?\n([\s\S]*?)```/g;
			let m;
			let lastHtml = '';
			while ((m = blockRegex.exec(fullContent)) !== null) {
				const lang = (m[1] || '').toLowerCase();
				const code = m[2] || '';
				if (lang === 'html' || (lang === '' && /<!doctype\s+html|<html[\s>]/i.test(code))) {
					lastHtml = code;
				}
			}
			return lastHtml;
		} catch (e) {
			return '';
		}
	}

	// Auto-abre preview quando o modelo comeca a gerar HTML/SVG
	$effect(() => {
		if (!incompleteCodeBlock) {
			// Stream pode ter terminado mas content tem novos blocos CSS/JS
			// Re-render se ainda esta previewing HTML
			if (previewDialogOpen && previewLanguage === 'html') {
				const baseHtml = extractLastHtmlBlock(content);
				if (baseHtml) {
					const combined = combineHtmlWithSiblings(content, baseHtml, null);
					if (combined !== previewCode) {
						previewCode = combined;
					}
				}
			}
			return;
		}
		const lang = (incompleteCodeBlock.language || '').toLowerCase();
		const blockCode = incompleteCodeBlock.code || '';
		const isCssJs = lang === 'css' || lang === 'js' || lang === 'javascript';
		const isPreviewableHtml =
			lang === 'html' ||
			(lang === '' && /<!doctype\s+html|<html[\s>]/i.test(blockCode));
		const isPreviewableSvg =
			lang === 'svg' ||
			(lang === 'xml' && /<svg[\s>]/i.test(blockCode)) ||
			(lang === '' && /<svg[\s>]/i.test(blockCode));
		const isPreviewable = isPreviewableHtml || isPreviewableSvg;

		if (!isPreviewable) {
			if (autoPreviewClosedByUser) return;
			// HTML nesta mesma mensagem? (CSS/JS apos HTML no mesmo bloco)
			const htmlInThisMsg = extractLastHtmlBlock(content);
			if (htmlInThisMsg) {
				if (previewDialogOpen && previewLanguage === 'html') {
					const combined = combineHtmlWithSiblings(content, htmlInThisMsg, incompleteCodeBlock);
					if (combined !== previewCode) {
						previewCode = combined;
					}
				}
				return;
			}
			// Sem HTML nesta mensagem: se for bloco CSS/JS e houver um preview de
			// iteracao ativo + HTML base de uma mensagem anterior, combina pra
			// refletir o ajuste (ex: usuario pediu mudanca so no CSS)
			if (isCssJs && previewCoordinator.activeId !== null && previewCoordinator.lastHtmlBase) {
				const combined = combineHtmlWithSiblings(content, previewCoordinator.lastHtmlBase, incompleteCodeBlock);
				previewCode = combined;
				previewLanguage = 'html';
				if (!previewDialogOpen) {
					previewDialogOpen = true;
				}
			}
			return;
		}

		if (autoPreviewClosedByUser) return;

		if (isPreviewableSvg) {
			previewCode = blockCode;
			previewLanguage = 'svg';
		} else {
			// HTML: guarda como base global e combina com blocos CSS/JS irmaos
			previewCoordinator.setHtmlBase(blockCode);
			previewCode = combineHtmlWithSiblings(content, blockCode, incompleteCodeBlock);
			previewLanguage = 'html';
		}
		if (!previewDialogOpen) {
			previewDialogOpen = true;
		}
	});
	$effect(() => {
		if (incompleteCodeBlock === null) {
			autoPreviewClosedByUser = false;
		}
	});

};
    },
    "MarkdownContent: effects de auto-preview com combine HTML+CSS+JS"
);

patch_file(
    $markdown_content,
    qr/(function handlePreviewDialogOpenChange\(open: boolean\) \{\s*previewDialogOpen = open;)(\s*if \(!open\) \{)/s,
    sub { "$1\n\t\tif (!open && incompleteCodeBlock !== null) {\n\t\t\tautoPreviewClosedByUser = true;\n\t\t}$2" },
    "MarkdownContent: rastreia close explicito"
);

# Patch handlePreviewClick para combinar HTML com CSS/JS irmaos
patch_file(
    $markdown_content,
    qr/(previewCode = info\.rawCode;\s*previewLanguage = info\.language;)/s,
    sub {
        return q{const isHtml = info.language.toLowerCase() === 'html' || /<!doctype\s+html|<html[\s>]/i.test(info.rawCode);
		if (isHtml) {
			previewCode = combineHtmlWithSiblings(content, info.rawCode, incompleteCodeBlock);
			previewLanguage = 'html';
		} else {
			previewCode = info.rawCode;
			previewLanguage = info.language;
		}};
    },
    "MarkdownContent: handlePreviewClick combina HTML+CSS+JS"
);

# ===========================================================================
# Botao Endpoints no menu lateral + modal centralizado
# ===========================================================================

print "\n[4] Botao Endpoints no menu lateral...\n";

my $sidebar_actions = "$webui_src/lib/components/app/navigation/SidebarNavigation/SidebarNavigationActions.svelte";

# ---------------------------------------------------------------------------
# 4.1 / 4.2 - REESCRITOS (upstream 2026-07-07 reorganizou a navegacao).
#
# O DesktopIconStrip.svelte foi deletado e o seu conteudo virou o branch
# {:else} deste mesmo SidebarNavigationActions.svelte, que hoje tem 3 ramos:
#   {#if isSearchModeActive}                -> SearchInput
#   {:else if isExpandedMode || isOnMobile} -> menu expandido (botoes COM TEXTO)
#   {:else}                                 -> icon strip (botoes SO ICONE)
#
# O 4.1 antigo substituia o <script> INTEIRO por um bloco escrito para a API
# antiga do componente. Ele casava (nao warnava!) e apagava do upstream
# ICON_CLASS_DEFAULT/goto/Search/ActionIcon/isMobile/TooltipSide/fade/circIn/
# ROUTES/initialized/showIcons/isItemActive/isExpandedMode/isOnMobile/
# onNewChat/onSearchClick - todos usados no template. Era o estrago real e
# nao aparecia em nenhum warn. Agora 4.1a/4.1b apenas INSEREM, deixando o
# script do upstream intacto.
# ---------------------------------------------------------------------------
# ---- 4.1a imports
patch_file(
    $sidebar_actions,
    qr{(import type \{ Component \} from 'svelte';)(?!\s*import \{ Dialog as DialogPrimitive \})},
    sub { $1 . q{
	import { Dialog as DialogPrimitive } from 'bits-ui';
	import { Plug, Copy, Check, X as XIcon, UserPlus, Trash2, LogOut, Server } from '@lucide/svelte';
	import { previewCoordinator } from '$lib/stores/preview-coordinator.svelte';
	import { sidebarPanels } from '$lib/stores/sidebar-panels.svelte';} },
    "SidebarNavigationActions: imports dos modais"
);

# ---- 4.1b estado + funcoes
patch_file(
    $sidebar_actions,
    qr{\A((?:(?!let endpointsModalOpen)[\s\S])*?)\n</script>},
    sub { $1 . q{

	// ---- customizacoes: modais de Endpoints / Usuarios / Servidores SSH ----

	// Compat: em versoes antigas do componente isto era uma prop que fechava o
	// drawer no celular ao clicar num item. O upstream atual nao expoe nada
	// equivalente, entao vira no-op - os modais abrem por cima da sidebar.
	function handleMobileSidebarItemClick() {}

	let endpointsModalOpen = $state(false);
	let usersModalOpen = $state(false);
	let sshServersModalOpen = $state(false);
	let copied = $state<Record<string, boolean>>({});
	let baseUrl = $state('');
	let availableModels = $state<string[]>([]);
	let modelsLoaded = $state(false);

	// Conta logada (vinda do gateway de autenticacao)
	let me = $state<{ username: string; role: string; token: string } | null>(null);
	const isAdmin = $derived(me?.role === 'admin');
	const myToken = $derived(me?.token || '');

	// Gerenciamento de usuarios (somente admin)
	let users = $state<Array<{ username: string; role: string; token: string; created: string }>>([]);
	let newUsername = $state('');
	let newPassword = $state('');
	let newRole = $state('user');
	let createError = $state('');
	let creating = $state(false);

	// Servidores SSH salvos (cada usuario gerencia e usa os seus)
	let sshServers = $state<Array<{ name: string; host: string; port: string; username: string }>>([]);
	let srvName = $state('');
	let srvHost = $state('');
	let srvPort = $state('22');
	let srvUser = $state('');
	let srvPass = $state('');
	let srvError = $state('');
	let srvSaving = $state(false);

	async function loadMe() {
		if (typeof window === 'undefined') return;
		baseUrl = window.location.origin;
		try {
			const res = await fetch(`${baseUrl}/gw/me`, { credentials: 'same-origin' });
			if (res.ok) me = await res.json();
		} catch (e) {
			// gateway ausente: segue sem login
		}
	}

	onMount(() => {
		loadMe();
	});

	export function activateSearch() {
		previewCoordinator.requestCloseAll();
		isSearchModeActive = true;
		queueMicrotask(() => searchInputRef?.focus());
	}

	async function loadModels() {
		if (modelsLoaded || typeof window === 'undefined') return;
		baseUrl = window.location.origin;
		try {
			const res = await fetch(`${baseUrl}/v1/models`, { credentials: 'same-origin' });
			if (res.ok) {
				const data = await res.json();
				availableModels = (data.data || []).map((m: { id: string }) => m.id);
				modelsLoaded = true;
			}
		} catch (e) {
			// silencioso
		}
	}

	function openEndpointsModal() {
		previewCoordinator.requestCloseAll();
		endpointsModalOpen = true;
		loadMe();
		loadModels();
		handleMobileSidebarItemClick();
	}

	async function loadUsers() {
		if (typeof window === 'undefined') return;
		try {
			const res = await fetch(`${baseUrl}/gw/users`, { credentials: 'same-origin' });
			if (res.ok) {
				const data = await res.json();
				users = data.users || [];
			}
		} catch (e) {
			// silencioso
		}
	}

	function openUsersModal() {
		previewCoordinator.requestCloseAll();
		usersModalOpen = true;
		createError = '';
		loadMe();
		loadUsers();
		handleMobileSidebarItemClick();
	}

	async function createUser() {
		createError = '';
		if (!newUsername.trim() || newPassword.length < 4) {
			createError = 'Informe um usuário e uma senha de pelo menos 4 caracteres.';
			return;
		}
		creating = true;
		try {
			const res = await fetch(`${baseUrl}/gw/users`, {
				method: 'POST',
				credentials: 'same-origin',
				headers: { 'Content-Type': 'application/json' },
				body: JSON.stringify({ username: newUsername.trim(), password: newPassword, role: newRole })
			});
			const data = await res.json();
			if (!res.ok) {
				createError = data.error || 'Falha ao criar usuário.';
			} else {
				newUsername = '';
				newPassword = '';
				newRole = 'user';
				await loadUsers();
			}
		} catch (e) {
			createError = 'Erro de rede ao criar usuário.';
		} finally {
			creating = false;
		}
	}

	async function deleteUser(username: string) {
		if (typeof window === 'undefined') return;
		if (!confirm(`Excluir o usuário "${username}"? O token dele deixará de funcionar.`)) return;
		try {
			const res = await fetch(`${baseUrl}/gw/users/${encodeURIComponent(username)}`, {
				method: 'DELETE',
				credentials: 'same-origin'
			});
			if (res.ok) await loadUsers();
		} catch (e) {
			// silencioso
		}
	}

	async function loadSshServers() {
		if (typeof window === 'undefined') return;
		try {
			const res = await fetch(`${baseUrl}/gw/ssh-servers`, { credentials: 'same-origin' });
			if (res.ok) {
				const data = await res.json();
				sshServers = data.servers || [];
			}
		} catch (e) {
			// silencioso
		}
	}

	function openSshServersModal() {
		previewCoordinator.requestCloseAll();
		sshServersModalOpen = true;
		srvError = '';
		loadMe();
		loadSshServers();
		handleMobileSidebarItemClick();
	}

	async function createSshServer() {
		srvError = '';
		if (!srvName.trim() || !srvHost.trim() || !srvUser.trim() || !srvPass) {
			srvError = 'Preencha nome, host, usuário e senha.';
			return;
		}
		srvSaving = true;
		try {
			const res = await fetch(`${baseUrl}/gw/ssh-servers`, {
				method: 'POST',
				credentials: 'same-origin',
				headers: { 'Content-Type': 'application/json' },
				body: JSON.stringify({
					name: srvName.trim(),
					host: srvHost.trim(),
					port: srvPort.trim() || '22',
					username: srvUser.trim(),
					password: srvPass
				})
			});
			const data = await res.json();
			if (!res.ok) {
				srvError = data.error || 'Falha ao salvar servidor.';
			} else {
				srvName = '';
				srvHost = '';
				srvPort = '22';
				srvUser = '';
				srvPass = '';
				await loadSshServers();
			}
		} catch (e) {
			srvError = 'Erro de rede ao salvar servidor.';
		} finally {
			srvSaving = false;
		}
	}

	async function deleteSshServer(name: string) {
		if (typeof window === 'undefined') return;
		if (!confirm(`Remover o servidor "${name}"?`)) return;
		try {
			const res = await fetch(`${baseUrl}/gw/ssh-servers/${encodeURIComponent(name)}`, {
				method: 'DELETE',
				credentials: 'same-origin'
			});
			if (res.ok) await loadSshServers();
		} catch (e) {
			// silencioso
		}
	}

	function logout() {
		if (typeof window !== 'undefined') window.location.href = '/logout';
	}

	// O icon strip (menu encolhido) pede pra abrir estes modais via sinais.
	let lastEpSig = 0;
	$effect(() => {
		const s = sidebarPanels.endpointsSignal;
		if (s !== lastEpSig) { lastEpSig = s; openEndpointsModal(); }
	});
	let lastUsersSig = 0;
	$effect(() => {
		const s = sidebarPanels.usersSignal;
		if (s !== lastUsersSig) { lastUsersSig = s; openUsersModal(); }
	});
	let lastSshSig = 0;
	$effect(() => {
		const s = sidebarPanels.sshSignal;
		if (s !== lastSshSig) { lastSshSig = s; openSshServersModal(); }
	});

	function copy(key: string, text: string) {
		if (!text || typeof navigator === 'undefined') return;
		navigator.clipboard.writeText(text);
		copied[key] = true;
		setTimeout(() => { copied[key] = false; }, 1500);
	}

	const firstModel = $derived(availableModels[0] || '<MODEL_ID>');
	const curlExample = $derived(`curl -X POST ${baseUrl}/v1/chat/completions \\
  -H "Authorization: Bearer ${myToken || '<SEU_TOKEN>'}" \\
  -H "Content-Type: application/json" \\
  -d '{"model":"${firstModel}","messages":[{"role":"user","content":"Olá"}]}'`);
</script>} },
    "SidebarNavigationActions: script com estado do modal"
);

# ---- 4.2a botoes COM TEXTO no branch expandido
patch_file(
    $sidebar_actions,
    qr{(\{/each\})(\s*</div>\s*\{:else\})}s,
    sub { $1 . q{
		<Button
			class="w-full justify-between px-2 backdrop-blur-none! hover:[&>kbd]:opacity-100"
			onclick={openEndpointsModal}
			variant="ghost"
		>
			<div class="flex items-center gap-2">
				<Plug class="h-4 w-4" />
				Endpoints da API
			</div>
		</Button>
		{#if isAdmin}
			<Button
				class="w-full justify-between px-2 backdrop-blur-none! hover:[&>kbd]:opacity-100"
				onclick={openUsersModal}
				variant="ghost"
			>
				<div class="flex items-center gap-2">
					<UserPlus class="h-4 w-4" />
					Usuários
				</div>
			</Button>
		{/if}
		<Button
			class="w-full justify-between px-2 backdrop-blur-none! hover:[&>kbd]:opacity-100"
			onclick={openSshServersModal}
			variant="ghost"
		>
			<div class="flex items-center gap-2">
				<Server class="h-4 w-4" />
				Servidores SSH
			</div>
		</Button>
		<Button
			class="w-full justify-between px-2 backdrop-blur-none! hover:[&>kbd]:opacity-100"
			onclick={logout}
			variant="ghost"
		>
			<div class="flex items-center gap-2">
				<LogOut class="h-4 w-4" />
				Sair
			</div>
		</Button>
	} . $2 },
    "SidebarNavigationActions: botoes com texto (menu expandido)"
);

# ---- 4.2b botoes SO ICONE no branch encolhido + modais no fim
patch_file(
    $sidebar_actions,
    qr{(\{/each\})(\s*</div>\s*\{/if\}\s*)\z}s,
    sub { $1 . q{
		<Button class="h-9 w-9 p-0" onclick={openEndpointsModal} variant="ghost" title="Endpoints da API">
			<Plug class="h-4 w-4" />
		</Button>
		{#if isAdmin}
			<Button class="h-9 w-9 p-0" onclick={openUsersModal} variant="ghost" title="Usuários">
				<UserPlus class="h-4 w-4" />
			</Button>
		{/if}
		<Button class="h-9 w-9 p-0" onclick={openSshServersModal} variant="ghost" title="Servidores SSH">
			<Server class="h-4 w-4" />
		</Button>
		<Button class="h-9 w-9 p-0" onclick={logout} variant="ghost" title="Sair">
			<LogOut class="h-4 w-4" />
		</Button>
	} . $2 . q{

<!-- Modal de Endpoints -->
<DialogPrimitive.Root bind:open={endpointsModalOpen}>
	<DialogPrimitive.Portal>
		<DialogPrimitive.Overlay
			class="fixed inset-0 z-[100000] bg-black/60 backdrop-blur-sm data-[state=open]:animate-in data-[state=closed]:animate-out data-[state=closed]:fade-out-0 data-[state=open]:fade-in-0"
		/>
		<DialogPrimitive.Content
			class="fixed left-[50%] top-[50%] z-[100001] grid w-[calc(100vw-2rem)] max-w-md translate-x-[-50%] translate-y-[-50%] gap-3 border bg-background p-5 shadow-lg duration-200 sm:rounded-lg max-h-[85dvh] overflow-y-auto data-[state=open]:animate-in data-[state=closed]:animate-out data-[state=closed]:fade-out-0 data-[state=open]:fade-in-0 data-[state=closed]:zoom-out-95 data-[state=open]:zoom-in-95"
		>
			<div class="flex items-center justify-between border-b pb-3">
				<div>
					<DialogPrimitive.Title class="text-lg font-semibold">Endpoints da API</DialogPrimitive.Title>
					<DialogPrimitive.Description class="text-sm text-muted-foreground">
						Use estes endpoints para conectar com n8n, Open WebUI, LangChain, Continue.dev ou qualquer cliente compatível com OpenAI.
					</DialogPrimitive.Description>
				</div>
				<DialogPrimitive.Close class="rounded-sm opacity-70 hover:opacity-100 transition-opacity p-1">
					<XIcon class="h-5 w-5" />
				</DialogPrimitive.Close>
			</div>

			<div class="space-y-4 text-sm">
				<div class="space-y-1">
					<div class="text-xs font-medium text-muted-foreground">URL Base</div>
					<div class="flex items-center gap-2">
						<code class="flex-1 truncate rounded bg-muted px-3 py-2 text-xs font-mono">{baseUrl}/v1</code>
						<button class="rounded p-2 hover:bg-accent border" onclick={() => copy('url', `${baseUrl}/v1`)} aria-label="Copiar URL">
							{#if copied.url}<Check class="h-4 w-4 text-green-500" />{:else}<Copy class="h-4 w-4" />{/if}
						</button>
					</div>
				</div>

				<div class="space-y-1">
					<div class="text-xs font-medium text-muted-foreground">Seu token</div>
					<div class="flex items-center gap-2">
						<code class="flex-1 truncate rounded bg-muted px-3 py-2 text-xs font-mono">{myToken || '(faça login)'}</code>
						<button class="rounded p-2 hover:bg-accent border disabled:opacity-50" onclick={() => copy('key', myToken)} disabled={!myToken} aria-label="Copiar token">
							{#if copied.key}<Check class="h-4 w-4 text-green-500" />{:else}<Copy class="h-4 w-4" />{/if}
						</button>
					</div>
				</div>

				<div class="space-y-1">
					<div class="text-xs font-medium text-muted-foreground">Modelos disponíveis ({availableModels.length})</div>
					<div class="space-y-1 max-h-40 overflow-y-auto rounded border p-2">
						{#each availableModels as model (model)}
							<div class="flex items-center gap-2">
								<code class="flex-1 truncate rounded bg-muted px-2 py-1 text-xs font-mono">{model}</code>
								<button class="rounded p-1.5 hover:bg-accent" onclick={() => copy('m-' + model, model)} aria-label="Copiar nome do modelo">
									{#if copied['m-' + model]}<Check class="h-3.5 w-3.5 text-green-500" />{:else}<Copy class="h-3.5 w-3.5" />{/if}
								</button>
							</div>
						{:else}
							<div class="text-xs text-muted-foreground py-1 px-2">Nenhum modelo carregado</div>
						{/each}
					</div>
				</div>

				<div class="space-y-1">
					<div class="text-xs font-medium text-muted-foreground">Endpoints</div>
					<div class="space-y-1 rounded border p-3 text-xs">
						<div class="flex items-center gap-2"><span class="rounded bg-emerald-100 dark:bg-emerald-950 px-1.5 py-0.5 text-[10px] font-semibold text-emerald-700 dark:text-emerald-300">POST</span><code class="flex-1 font-mono">/v1/chat/completions</code><span class="text-muted-foreground">Chat (OpenAI)</span></div>
						<div class="flex items-center gap-2"><span class="rounded bg-emerald-100 dark:bg-emerald-950 px-1.5 py-0.5 text-[10px] font-semibold text-emerald-700 dark:text-emerald-300">POST</span><code class="flex-1 font-mono">/v1/completions</code><span class="text-muted-foreground">Completion</span></div>
						<div class="flex items-center gap-2"><span class="rounded bg-emerald-100 dark:bg-emerald-950 px-1.5 py-0.5 text-[10px] font-semibold text-emerald-700 dark:text-emerald-300">POST</span><code class="flex-1 font-mono">/v1/embeddings</code><span class="text-muted-foreground">Embeddings</span></div>
						<div class="flex items-center gap-2"><span class="rounded bg-sky-100 dark:bg-sky-950 px-1.5 py-0.5 text-[10px] font-semibold text-sky-700 dark:text-sky-300">GET</span><code class="flex-1 font-mono">/v1/models</code><span class="text-muted-foreground">Listar modelos</span></div>
						<div class="flex items-center gap-2"><span class="rounded bg-sky-100 dark:bg-sky-950 px-1.5 py-0.5 text-[10px] font-semibold text-sky-700 dark:text-sky-300">GET</span><code class="flex-1 font-mono">/health</code><span class="text-muted-foreground">Health check</span></div>
					</div>
				</div>

				<div class="space-y-1">
					<div class="text-xs font-medium text-muted-foreground">Exemplo cURL</div>
					<div class="relative">
						<pre class="whitespace-pre-wrap break-all rounded bg-muted px-3 py-3 text-[11px] leading-relaxed font-mono pr-10"><code>{curlExample}</code></pre>
						<button class="absolute top-2 right-2 rounded p-1.5 bg-background/90 hover:bg-accent border" onclick={() => copy('curl', curlExample)} aria-label="Copiar exemplo">
							{#if copied.curl}<Check class="h-3.5 w-3.5 text-green-500" />{:else}<Copy class="h-3.5 w-3.5" />{/if}
						</button>
					</div>
				</div>
			</div>
		</DialogPrimitive.Content>
	</DialogPrimitive.Portal>
</DialogPrimitive.Root>

<!-- Modal Criar usuário -->
<DialogPrimitive.Root bind:open={usersModalOpen}>
	<DialogPrimitive.Portal>
		<DialogPrimitive.Overlay
			class="fixed inset-0 z-[100000] bg-black/60 backdrop-blur-sm data-[state=open]:animate-in data-[state=closed]:animate-out data-[state=closed]:fade-out-0 data-[state=open]:fade-in-0"
		/>
		<DialogPrimitive.Content
			class="fixed left-[50%] top-[50%] z-[100001] grid w-[calc(100vw-2rem)] max-w-md translate-x-[-50%] translate-y-[-50%] gap-3 border bg-background p-5 shadow-lg duration-200 sm:rounded-lg max-h-[85dvh] overflow-y-auto data-[state=open]:animate-in data-[state=closed]:animate-out data-[state=closed]:fade-out-0 data-[state=open]:fade-in-0 data-[state=closed]:zoom-out-95 data-[state=open]:zoom-in-95"
		>
			<div class="flex items-center justify-between border-b pb-3">
				<div>
					<DialogPrimitive.Title class="text-lg font-semibold">Usuários</DialogPrimitive.Title>
					<DialogPrimitive.Description class="text-sm text-muted-foreground">
						Cada usuário tem login próprio e um token de API exclusivo para usar em {baseUrl}/v1.
					</DialogPrimitive.Description>
				</div>
				<DialogPrimitive.Close class="rounded-sm opacity-70 hover:opacity-100 transition-opacity p-1">
					<XIcon class="h-5 w-5" />
				</DialogPrimitive.Close>
			</div>

			<div class="space-y-3 text-sm">
				<div class="grid gap-2">
					<input
						class="rounded border bg-background px-3 py-2 text-sm"
						placeholder="Usuário (ex: maria)"
						bind:value={newUsername}
						autocomplete="off"
					/>
					<input
						class="rounded border bg-background px-3 py-2 text-sm"
						type="password"
						placeholder="Senha (mín. 4 caracteres)"
						bind:value={newPassword}
						autocomplete="new-password"
					/>
					<select class="rounded border bg-background px-3 py-2 text-sm" bind:value={newRole}>
						<option value="user">Usuário comum</option>
						<option value="admin">Administrador</option>
					</select>
					{#if createError}
						<div class="rounded border border-red-500/40 bg-red-500/10 px-3 py-2 text-xs text-red-500">{createError}</div>
					{/if}
					<Button onclick={createUser} disabled={creating} class="w-full">
						{creating ? 'Criando...' : 'Criar usuário'}
					</Button>
				</div>

				<div class="space-y-1">
					<div class="text-xs font-medium text-muted-foreground">Usuários ({users.length})</div>
					<div class="space-y-2 max-h-[15rem] overflow-y-auto rounded border p-2">
						{#each users as u (u.username)}
							<div class="rounded border p-2 space-y-1">
								<div class="flex items-center justify-between gap-2">
									<div class="flex items-center gap-2 min-w-0">
										<span class="truncate font-medium">{u.username}</span>
										<span class="rounded bg-muted px-1.5 py-0.5 text-[10px] text-muted-foreground">{u.role}</span>
									</div>
									{#if u.username !== me?.username}
										<button class="rounded p-1.5 hover:bg-accent text-red-500" onclick={() => deleteUser(u.username)} aria-label="Excluir usuário">
											<Trash2 class="h-3.5 w-3.5" />
										</button>
									{/if}
								</div>
								<div class="flex items-center gap-2">
									<code class="flex-1 truncate rounded bg-muted px-2 py-1 text-[11px] font-mono">{u.token}</code>
									<button class="rounded p-1.5 hover:bg-accent border" onclick={() => copy('u-' + u.username, u.token)} aria-label="Copiar token">
										{#if copied['u-' + u.username]}<Check class="h-3.5 w-3.5 text-green-500" />{:else}<Copy class="h-3.5 w-3.5" />{/if}
									</button>
								</div>
							</div>
						{:else}
							<div class="text-xs text-muted-foreground py-1 px-2">Nenhum usuário ainda</div>
						{/each}
					</div>
				</div>
			</div>
		</DialogPrimitive.Content>
	</DialogPrimitive.Portal>
</DialogPrimitive.Root>

<!-- Modal Servidores SSH -->
<DialogPrimitive.Root bind:open={sshServersModalOpen}>
	<DialogPrimitive.Portal>
		<DialogPrimitive.Overlay
			class="fixed inset-0 z-[100000] bg-black/60 backdrop-blur-sm data-[state=open]:animate-in data-[state=closed]:animate-out data-[state=closed]:fade-out-0 data-[state=open]:fade-in-0"
		/>
		<DialogPrimitive.Content
			class="fixed left-[50%] top-[50%] z-[100001] grid w-[calc(100vw-2rem)] max-w-md translate-x-[-50%] translate-y-[-50%] gap-3 border bg-background p-5 shadow-lg duration-200 sm:rounded-lg max-h-[85dvh] overflow-y-auto data-[state=open]:animate-in data-[state=closed]:animate-out data-[state=closed]:fade-out-0 data-[state=open]:fade-in-0 data-[state=closed]:zoom-out-95 data-[state=open]:zoom-in-95"
		>
			<div class="flex items-center justify-between border-b pb-3">
				<div>
					<DialogPrimitive.Title class="text-lg font-semibold">Servidores SSH</DialogPrimitive.Title>
					<DialogPrimitive.Description class="text-sm text-muted-foreground">
						Salve servidores com nome. Depois é só pedir à IA: "acesse o servidor X e faça...".
					</DialogPrimitive.Description>
				</div>
				<DialogPrimitive.Close class="rounded-sm opacity-70 hover:opacity-100 transition-opacity p-1">
					<XIcon class="h-5 w-5" />
				</DialogPrimitive.Close>
			</div>

			<div class="space-y-3 text-sm">
				<div class="grid gap-2">
					<input class="rounded border bg-background px-3 py-2 text-sm" placeholder="Nome (ex: web1)" bind:value={srvName} autocomplete="off" />
					<div class="flex gap-2">
						<input class="flex-1 rounded border bg-background px-3 py-2 text-sm" placeholder="Host / IP" bind:value={srvHost} autocomplete="off" />
						<input class="w-24 rounded border bg-background px-3 py-2 text-sm" placeholder="Porta" bind:value={srvPort} autocomplete="off" />
					</div>
					<input class="rounded border bg-background px-3 py-2 text-sm" placeholder="Usuário" bind:value={srvUser} autocomplete="off" />
					<input class="rounded border bg-background px-3 py-2 text-sm" type="password" placeholder="Senha" bind:value={srvPass} autocomplete="new-password" />
					{#if srvError}
						<div class="rounded border border-red-500/40 bg-red-500/10 px-3 py-2 text-xs text-red-500">{srvError}</div>
					{/if}
					<Button onclick={createSshServer} disabled={srvSaving} class="w-full">
						{srvSaving ? 'Salvando...' : 'Salvar servidor'}
					</Button>
				</div>

				<div class="space-y-1">
					<div class="text-xs font-medium text-muted-foreground">Servidores salvos ({sshServers.length})</div>
					<div class="space-y-2 max-h-[11rem] overflow-y-auto rounded border p-2">
						{#each sshServers as s (s.name)}
							<div class="flex items-center justify-between gap-2 rounded border p-2">
								<div class="min-w-0">
									<div class="truncate font-medium">{s.name}</div>
									<div class="truncate text-[11px] text-muted-foreground">{s.username}@{s.host}:{s.port}</div>
								</div>
								<button class="rounded p-1.5 hover:bg-accent text-red-500" onclick={() => deleteSshServer(s.name)} aria-label="Remover servidor">
									<Trash2 class="h-3.5 w-3.5" />
								</button>
							</div>
						{:else}
							<div class="text-xs text-muted-foreground py-1 px-2">Nenhum servidor salvo</div>
						{/each}
					</div>
					<p class="text-[11px] text-muted-foreground">As senhas ficam no servidor (volume /auth), nunca no navegador.</p>
				</div>
			</div>
		</DialogPrimitive.Content>
	</DialogPrimitive.Portal>
</DialogPrimitive.Root>
} },
    "SidebarNavigationActions: botoes so icone (encolhido) + modais"
);

# 4.3: Reverter ChatScreenGreeting para versao traduzida sem painel
my $greeting = "$webui_src/lib/components/app/chat/ChatScreen/ChatScreenGreeting.svelte";
patch_file(
    $greeting,
    qr{<h1 class="mb-2 text-2xl font-semibold tracking-tight md:text-3xl">Hello there</h1>}s,
    q{<h1 class="mb-2 text-2xl font-semibold tracking-tight md:text-3xl">Olá!</h1>},
    "ChatScreenGreeting: titulo PT-BR"
);

# ===========================================================================
# Traducoes de template literals (interpolacao) que o translate.pl nao pega
# ===========================================================================

print "\n[5] Traduzindo template literals com interpolacao...\n";

my $settings_registry = "$webui_src/lib/constants/settings-registry.ts";

# Remove o campo "API Key" das configuracoes. A autenticacao agora eh via
# login/sessao e o token + endpoints ficam no menu lateral ("Endpoints da API"),
# entao esse campo nao serve mais.
patch_file(
    $settings_registry,
    qr{\{\s*key: SETTINGS_KEYS\.API_KEY,.*?section: SETTINGS_SECTION_SLUGS\.GENERAL\s*\},}s,
    "",
    "settings-registry: remove campo API Key"
);

# Confirmacao de excluir conversa: template literal com ${...} e aspas internas.
# O upstream ganhou window.confirm proprio, mas em ingles, e trocou a variavel
# selectedConversationNamePreview por conversation.name -- aqui so traduzimos.
my $sidebar_nav = "$webui_src/lib/components/app/navigation/SidebarNavigation/SidebarNavigation.svelte";
patch_file(
    $sidebar_nav,
    qr/`Delete\s+"\$\{conversation\.name\}"\?\s*This action cannot be undone\.`/,
    q{`Excluir "${conversation.name}"? Esta ação não pode ser desfeita.`},
    "SidebarNavigation: confirmacao de excluir conversa"
);

# Fechar preview ao expandir/colapsar o sidebar (toggle).
# O import direto do SidebarNavigationActions virou barrel import
# ('$lib/components/app'), entao a ancora passou a ser o import de ROUTES.
patch_file(
    $sidebar_nav,
    qr/(import \{\s*ROUTES\s*\} from '\$lib\/constants';)(?!\s*import \{ previewCoordinator \})/,
    sub { "$1\n\timport { previewCoordinator } from '\$lib/stores/preview-coordinator.svelte';" },
    "SidebarNavigation: importa previewCoordinator"
);
# Sidebar.useSidebar() nao existe mais: o estado agora eh o local isExpandedMode.
# Observar isExpandedMode cobre o toggle manual E as mudancas programaticas
# (alwaysShowSidebarOnDesktop, hash SEARCH no mobile, scheduleMobileCollapse).
patch_file(
    $sidebar_nav,
    qr/(let isExpandedMode\s*=\s*\$state\(false\);)(?!\s*\/\/ Fecha o preview)/,
    sub { "$1\n\t// Fecha o preview quando o sidebar eh expandido/colapsado\n\tlet lastSidebarOpenState = isExpandedMode;\n\t\$effect(() => {\n\t\tif (isExpandedMode !== lastSidebarOpenState) {\n\t\t\tlastSidebarOpenState = isExpandedMode;\n\t\t\tpreviewCoordinator.requestCloseAll();\n\t\t}\n\t});" },
    "SidebarNavigation: fecha preview ao toggle do sidebar"
);

# A tela de busca (rota nova) ganhou o MESMO confirm em ingles.
my $search_page = "$webui_src/routes/search/+page.svelte";
patch_file(
    $search_page,
    qr/`Delete\s+"\$\{conversation\.name\}"\?\s*This action cannot be undone\.`/,
    q{`Excluir "${conversation.name}"? Esta ação não pode ser desfeita.`},
    "search page: confirmacao de excluir conversa"
);

# Fechar preview ao abrir o menu "..." de acoes da conversa
my $conv_item = "$webui_src/lib/components/app/navigation/SidebarNavigation/SidebarNavigationConversationItem.svelte";
patch_file(
    $conv_item,
    qr/(import \{ conversationsStore \} from '\$lib\/stores\/conversations\.svelte';)/,
    sub { "$1\n\timport { previewCoordinator } from '\$lib/stores/preview-coordinator.svelte';" },
    "ConversationItem: importa previewCoordinator"
);
patch_file(
    $conv_item,
    qr/(let dropdownOpen = \$state\(false\);)/,
    sub { "$1\n\t// Fecha o preview quando o menu de acoes (...) eh aberto\n\tlet lastDropdownOpenState = false;\n\t\$effect(() => {\n\t\tif (dropdownOpen && !lastDropdownOpenState) {\n\t\t\tpreviewCoordinator.requestCloseAll();\n\t\t}\n\t\tlastDropdownOpenState = dropdownOpen;\n\t});" },
    "ConversationItem: fecha preview ao abrir menu de acoes"
);

# Rotulos de raciocinio. O ChatFormReasoningToggle.svelte foi REMOVIDO do
# upstream em f1161b15f (#25340, 2026-07-08): o botao dedicado de raciocinio
# na barra do chat deixou de existir e virou submenu dentro do menu "+".
# A logica comum (inclusive os rotulos de tokens) migrou para o hook
# lib/hooks/use-reasoning-menu.svelte.ts.
#
# DESCARTADOS (as strings nao existem mais em lugar nenhum do upstream e nao
# ha sucessor): o patch do tooltip `${currentEffort} Reasoning` e o do
# aria-label `${tooltipText}. Click to configure.`.
#
# ATENCAO: NAO apontar patch para
# ChatForm/ChatFormActions/ChatFormReasoningEffortSubmenu.svelte - ele contem
# as mesmas strings mas e codigo morto (ninguem importa); o patch casaria,
# imprimiria "+ ok" e mascararia a quebra real sem efeito nenhum na UI.
my $reasoning_menu = "$webui_src/lib/hooks/use-reasoning-menu.svelte.ts";
# `Max ${tokens.toLocaleString()} tokens`
patch_file(
    $reasoning_menu,
    qr/`Max\s+(\$\{[^}]+\})\s+tokens`/,
    sub { "`Máx $1 tokens`" },
    "reasoning-menu: max tokens"
);
# 'Unlimited' (nivel sem teto de tokens)
patch_file(
    $reasoning_menu,
    qr/(\?\s*)'Unlimited'/,
    sub { "$1'Ilimitado'" },
    "reasoning-menu: Unlimited"
);

# Rotulo "Reasoning" no submenu do desktop (menu "+")
my $reasoning_submenu =
    "$webui_src/lib/components/app/chat/ChatForm/ChatFormActions/ChatFormActionAdd/ChatFormActionAddReasoningSubmenu.svelte";
patch_file(
    $reasoning_submenu,
    qr/(>\s*)Reasoning(\s*<)/,
    sub { "$1Raciocínio$2" },
    "ReasoningSubmenu: rotulo Raciocinio"
);

# Rotulo "Reasoning" no sheet do mobile (menu "+")
my $chatform_add_sheet =
    "$webui_src/lib/components/app/chat/ChatForm/ChatFormActions/ChatFormActionAdd/ChatFormActionAddSheet.svelte";
patch_file(
    $chatform_add_sheet,
    qr/(<span[^>]*class="[^"]*flex-1[^"]*"[^>]*>)\s*Reasoning\s*(<\/span>)/,
    sub { "$1Raciocínio$2" },
    "ChatFormActionAddSheet: rotulo Raciocinio"
);

# Labels dos niveis de raciocinio (reasoning-effort.ts) - patch direto pra
# evitar traduzir 'Off'/'Low'/'High' globalmente (arriscado)
my $reasoning_effort = "$webui_src/lib/constants/reasoning-effort.ts";
patch_file($reasoning_effort, qr/label: 'Off', isOff: true/, "label: 'Desligado', isOff: true", "reasoning-effort: Off");
patch_file($reasoning_effort, qr/(ReasoningEffort\.LOW, )label: 'Low'/, sub { "$1label: 'Baixo'" }, "reasoning-effort: Low");
patch_file($reasoning_effort, qr/(ReasoningEffort\.MEDIUM, )label: 'Medium'/, sub { "$1label: 'Médio'" }, "reasoning-effort: Medium");
patch_file($reasoning_effort, qr/(ReasoningEffort\.HIGH, )label: 'High'/, sub { "$1label: 'Alto'" }, "reasoning-effort: High");
patch_file($reasoning_effort, qr/(ReasoningEffort\.MAX, )label: 'Max'/, sub { "$1label: 'Máximo'" }, "reasoning-effort: Max");

# ===========================================================================
# Footer das configuracoes: fundo solido pra nao deixar conteudo passar atras
# ===========================================================================

print "\n[6] Footer fixo das configuracoes (fundo solido)...\n";

my $settings_footer = "$webui_src/lib/components/app/settings/SettingsFooter.svelte";

# O footer ja eh sticky bottom-0, mas transparente: o conteudo rola por tras
# e fica visivel atraves dos botoes. Adiciona bg-background + border-t pra
# que fique opaco e visualmente separado. Remove mt-4 que empurrava.
patch_file(
    $settings_footer,
    qr/<div class="sticky bottom-0 mx-auto mt-4 flex w-full justify-between p-6">/,
    q{<div class="sticky bottom-0 z-10 mx-auto flex w-full justify-between border-t bg-background p-4">},
    "SettingsFooter: fundo solido + borda + sem mt-4"
);

# ===========================================================================
# Controle de acesso por papel: esconde "Configuracoes" de usuarios comuns,
# mantendo Endpoints, Servidor MCP e Ferramentas. Papel vem do gateway (/gw/me).
# ===========================================================================

print "\n[7] Controle de acesso (admin vs usuario comum)...\n";

# 7.0: Store compartilhado com o papel do usuario logado
my $auth_store = "$webui_src/lib/stores/auth.svelte.ts";
write_file($auth_store, <<'TS', "criado auth.svelte.ts (papel via /gw/me)");
// Conta logada, lida do gateway de autenticacao (/gw/me).
// Compartilhado entre a sidebar, o icon strip e as Configuracoes para
// esconder a area de Configuracoes de usuarios comuns (nao-admin).
import { browser } from '$app/environment';

let username = $state('');
let role = $state('');
let loaded = $state(false);
let loading = false;

async function load() {
	if (!browser || loading || loaded) return;
	loading = true;
	try {
		const res = await fetch(`${window.location.origin}/gw/me`, { credentials: 'same-origin' });
		if (res.ok) {
			const data = await res.json();
			username = data.username || '';
			role = data.role || '';
		}
	} catch (e) {
		// gateway ausente: segue como nao-admin
	} finally {
		loaded = true;
		loading = false;
	}
}

if (browser) load();

export const authStore = {
	get username() {
		return username;
	},
	get role() {
		return role;
	},
	get isAdmin() {
		return role === 'admin';
	},
	get loaded() {
		return loaded;
	},
	ensureLoaded: load
};
TS

# 7.1: ui.ts - importa Wrench, adiciona campo adminOnly, item "Ferramentas"
#      e marca "Settings" como adminOnly.
# O upstream reordenou os nomes do import lucide (alfabetica) e trocou
# route/active* do item Settings, entao os regex casam por ESTRUTURA e nao
# por texto literal. Todos idempotentes.
my $ui_consts = "$webui_src/lib/constants/ui.ts";

patch_file($ui_consts,
    qr{(import\s*\{(?![^\}]*\bWrench\b)[^\}]*?)\s*(\}\s*from\s*'\@lucide/svelte';)},
    sub { "$1, Wrench $2" },
    "ui.ts: importa Wrench");

patch_file($ui_consts,
    qr{keys\?:\s*string\[\];(?!(?s:.*)adminOnly\?)},
    sub { "keys?: string[];\n\t/** Item visivel apenas para admin (filtrado no menu lateral). */\n\tadminOnly?: boolean;" },
    "ui.ts: campo adminOnly na interface");

# Insere o item "Ferramentas" antes do item Settings e marca Settings como
# adminOnly, preservando os campos que o upstream definir no proprio item.
# O (?!\},) impede a captura de atravessar a fronteira de outro objeto do
# array: se o Settings deixar de ser o ultimo item, o patch NAO casa (falha
# alta) em vez de corromper o arquivo.
patch_file($ui_consts,
    qr{(\{\s*icon:\s*Settings\b(?:(?!\},)(?!adminOnly).)*?)(\s*\}\s*\];)}s,
    sub { q{{
		icon: Wrench,
		tooltip: 'Ferramentas',
		route: `${ROUTES.SETTINGS}/tools`,
		activeUrlIncludes: '#/settings/tools'
	},
	} . $1 . q{,
		adminOnly: true} . $2 },
    "ui.ts: item Ferramentas + Settings adminOnly");

# O item "MCP Servers" e novo no upstream e leva a configuracao global de
# servidores MCP - mesma classe de risco do Settings. Fecha pra usuario comum.
patch_file($ui_consts,
    qr{(\{\s*icon:\s*McpLogo\b(?:(?!\},)(?!adminOnly).)*?)(\s*\},)}s,
    sub { $1 . q{,
		adminOnly: true} . $2 },
    "ui.ts: MCP Servers adminOnly");

# 7.2: DESCARTADO. O DesktopIconStrip.svelte foi deletado pelo upstream em
#      ab6120cde (o strip de icones virou o branch {:else} deste mesmo
#      SidebarNavigationActions.svelte). Os 3 patches que filtravam os itens
#      por papel dentro do strip ficaram sem alvo; o filtro agora e feito de
#      uma vez so pelo 7.3, cujo s///g cobre os DOIS {#each} do componente.
#      Tambem nao ha mais motivo pra importar o authStore la: o script do
#      4.1b ja define isAdmin a partir do /gw/me (fonte unica de verdade).

# ---- 7.3 filtro por papel
patch_file($sidebar_actions,
    qr{(const isAdmin = \$derived\(me\?\.role === 'admin'\);)(?!\s*const visibleActionItems)},
    sub { $1 . "\n\tconst visibleActionItems = \$derived(\n\t\tSIDEBAR_ACTIONS_ITEMS.filter((it) => !it.adminOnly || isAdmin)\n\t);" },
    "SidebarNavigationActions: visibleActionItems por papel");
patch_file($sidebar_actions,
    qr{\{#each\s+SIDEBAR_ACTIONS_ITEMS\s+as\s+(item[^)]*\([^)]*\))\s*\}},
    sub { "{#each visibleActionItems as $1}" },
    "SidebarNavigationActions: each filtra por papel");

# 7.4: SettingsChat — usuario comum ve so a secao Ferramentas
my $settings_chat = "$webui_src/lib/components/app/settings/SettingsChat/SettingsChat.svelte";
patch_file($settings_chat,
    qr{import \{ isRouterMode \} from '\$lib/stores/server\.svelte';},
    sub { "import { isRouterMode } from '\$lib/stores/server.svelte';\n\timport { authStore } from '\$lib/stores/auth.svelte';" },
    "SettingsChat: importa authStore");
patch_file($settings_chat,
    qr{let currentSection = \$derived\(\s*SETTINGS_CHAT_SECTIONS\.find\(\(section\) => section\.slug === activeSlug\) \|\|\s*SETTINGS_CHAT_SECTIONS\[0\]\s*\);}s,
    q{const visibleSections = $derived(
		authStore.isAdmin
			? SETTINGS_CHAT_SECTIONS
			: SETTINGS_CHAT_SECTIONS.filter((s) => s.slug === 'tools')
	);

	let currentSection = $derived(
		visibleSections.find((section) => section.slug === activeSlug) ||
			visibleSections[0] ||
			SETTINGS_CHAT_SECTIONS[0]
	);},
    "SettingsChat: visibleSections por papel + currentSection");
patch_file($settings_chat,
    qr{sections=\{SETTINGS_CHAT_SECTIONS\}},
    q{sections={visibleSections}},
    "SettingsChat: passa visibleSections (desktop + mobile)");

# ===========================================================================
# Botoes customizados tambem no icon strip (menu lateral encolhido)
# ===========================================================================

print "\n[8] Botoes customizados no menu encolhido (icon strip)...\n";

# Store-ponte: o icon strip incrementa um sinal e o SidebarNavigationActions
# (sempre montado, mesmo encolhido) observa e abre o modal correspondente.
my $sidebar_panels = "$webui_src/lib/stores/sidebar-panels.svelte.ts";
write_file($sidebar_panels, <<'TS', "criado sidebar-panels.svelte.ts");
// Ponte entre o icon strip (menu encolhido) e os modais que vivem no
// SidebarNavigationActions (sempre montado). O icon strip incrementa um
// sinal; o SidebarNavigationActions observa e abre o modal.
let endpointsSignal = $state(0);
let usersSignal = $state(0);
let sshSignal = $state(0);

export const sidebarPanels = {
	get endpointsSignal() {
		return endpointsSignal;
	},
	get usersSignal() {
		return usersSignal;
	},
	get sshSignal() {
		return sshSignal;
	},
	openEndpoints() {
		endpointsSignal++;
	},
	openUsers() {
		usersSignal++;
	},
	openSshServers() {
		sshSignal++;
	}
};
TS

# DESCARTADOS: os 2 patches que injetavam os botoes no DesktopIconStrip
# (importar store-ponte + icones, e inserir Endpoints/Usuarios/SSH/Sair depois
# do loop). O arquivo nao existe mais, e o branch {:else} do
# SidebarNavigationActions -- que é o antigo icon strip -- ja recebe os botoes
# SO ICONE pelo patch 4.2b la em cima. Reinjetar aqui duplicaria os botoes.
#
# O write_file do sidebar-panels.svelte.ts acima CONTINUA necessario: o
# script montado pelo 4.1a ainda importa esse store (os 3 $effect de sinal
# ficaram inertes, mas o import precisa resolver ou o build quebra).

# ===========================================================================
# Resumo final: qualquer patch CRITICO que nao casou quebra o build.
# ===========================================================================

print "\n";
print "-" x 60, "\n";
printf "%d aplicados, %d falharam\n", $applied, $failed;
if (@skipped_optional) {
    printf "%d opcionais ignorados: %s\n",
        scalar(@skipped_optional), join(', ', @skipped_optional);
}

if ($failed) {
    print STDERR "\nPATCHES CRITICOS QUE NAO CASARAM:\n";
    print STDERR "  - $_\n" for @failures;
    print STDERR "\nO upstream mudou. Corrija o customizations/apply.pl antes de\n";
    print STDERR "publicar - a imagem sairia degradada (WebUI sem traducao, sem\n";
    print STDERR "botoes de gestao ou sem controle de acesso admin/usuario).\n";
    exit 1;
}

print "Customizacoes aplicadas.\n";
exit 0;