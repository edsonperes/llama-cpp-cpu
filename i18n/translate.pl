#!/usr/bin/perl
# translate.pl - Aplica traducoes PT-BR ao codigo fonte da WebUI do llama.cpp
#
# Uso: translate.pl <webui_src_dir> <translations_file>
#
# Diferencial vs sed: processa o arquivo inteiro de uma vez, suportando
# strings multi-linha em JSX, atributos com aspas duplas/simples,
# texto livre em proprias linhas dentro de elementos, etc.

use strict;
use warnings;
use utf8;
use open ':std', ':utf8';
use File::Find;

my ($webui_dir, $translations_file) = @ARGV;

unless (defined $webui_dir && defined $translations_file) {
    die "Uso: $0 <webui_src_dir> <translations_file>\n";
}
unless (-d $webui_dir) {
    die "Erro: diretorio '$webui_dir' nao existe\n";
}
unless (-f $translations_file) {
    die "Erro: arquivo '$translations_file' nao existe\n";
}

print "Aplicando traducoes PT-BR de $translations_file em $webui_dir\n";

# ----------------------------------------------------------------
# Ler pares de traducao
# ----------------------------------------------------------------
my @pairs;
open(my $fh, '<:encoding(UTF-8)', $translations_file)
    or die "Nao foi possivel abrir $translations_file: $!";
my $linenum = 0;
while (my $line = <$fh>) {
    $linenum++;
    chomp $line;
    next if $line =~ /^\s*#/;
    next if $line =~ /^\s*$/;

    # Formato esperado: "EN" => "PT"
    # Greedy: aceita aspas duplas internas
    if ($line =~ /^"(.+)"\s*=>\s*"(.+)"\s*$/) {
        my ($en, $pt) = ($1, $2);
        push @pairs, [$en, $pt];
    } else {
        warn "  ! Linha $linenum ignorada (formato invalido): $line\n";
    }
}
close $fh;
print "Total de pares de traducao: ", scalar(@pairs), "\n";

# ----------------------------------------------------------------
# Coletar arquivos alvo
# ----------------------------------------------------------------
my @target_files;
find(
    {
        wanted => sub {
            return unless -f $_;
            return unless /\.(svelte|ts|js)$/;
            return if $File::Find::dir =~ m{/node_modules(/|$)};
            return if $File::Find::dir =~ m{/\.svelte-kit(/|$)};
            return if $File::Find::dir =~ m{/build(/|$)};
            return if $File::Find::dir =~ m{/dist(/|$)};
            push @target_files, $File::Find::name;
        },
        no_chdir => 1,
    },
    $webui_dir
);
print "Total de arquivos alvo: ", scalar(@target_files), "\n";

# ----------------------------------------------------------------
# Atributos seguros para traducao (allow-list)
# Atributos como type, name, id, class, bind:, on:, use: NUNCA sao tocados
# ----------------------------------------------------------------
my @safe_attrs = qw(
    aria-label aria-description aria-placeholder aria-valuetext aria-roledescription
    title placeholder alt label description text message tooltip
    confirmText cancelText submitText helperText helpText
    errorMessage successMessage warningMessage infoMessage
    legend caption summary heading subtitle subheading
);

# ----------------------------------------------------------------
# Processar cada arquivo
# ----------------------------------------------------------------
my $files_modified = 0;
my $total_replacements = 0;

for my $file (@target_files) {
    open(my $in, '<:encoding(UTF-8)', $file) or do {
        warn "Nao foi possivel ler $file: $!\n";
        next;
    };
    local $/;
    my $content = <$in>;
    close $in;

    my $original = $content;
    my $file_replacements = 0;

    for my $pair (@pairs) {
        my ($en, $pt) = @$pair;
        my $en_quoted = quotemeta($en);
        # Permite que cada whitespace na string EN case com qualquer
        # sequencia de whitespace (incluindo newlines + indentacao) na fonte.
        # Isso resolve textos JSX multi-linha como:
        #   <p>
        #     Download all your conversations as a JSON file. This includes...
        #     conversation history.
        #   </p>
        my $en_flexible = $en_quoted;
        $en_flexible =~ s/(\\\s)+/\\s+/g;

        # ------------------------------------------------------------
        # 1. Texto JSX (entre tags ou apos interpolacao), suporta multi-linha
        #    >  EN  < => >  PT  <
        #    }  EN  < => }  PT  <    (apos {expressao})
        # ------------------------------------------------------------
        my $count1 = 0;
        $count1 += ($content =~ s/([>}])(\s*)$en_flexible(\s*)(<)/$1$2$pt$3$4/g);
        $file_replacements += $count1;

        # 1b. Texto JSX antes de interpolacao: > EN { ... }
        $file_replacements += ($content =~ s/(>)(\s*)$en_flexible(\s*)(\{)/$1$2$pt$3$4/g);

        # ------------------------------------------------------------
        # 2. Atributos seguros (aria-label, title, placeholder, etc)
        #    Aspas duplas e simples
        # ------------------------------------------------------------
        for my $attr (@safe_attrs) {
            my $attr_re = quotemeta($attr);
            $file_replacements += ($content =~ s/(\b$attr_re=")\Q$en\E(")/$1$pt$2/g);
            $file_replacements += ($content =~ s/(\b$attr_re=')\Q$en\E(')/$1$pt$2/g);
        }

        # ------------------------------------------------------------
        # 3. String literal em codigo TS/JS em contexto seguro
        #    Precedida por =, :, (, [, {, virgula, ou whitespace
        #    Seguida por ), , ; ., ], }, whitespace
        #    Aspas duplas e simples
        # ------------------------------------------------------------
        $file_replacements += ($content =~ s/([=:,(\[\{\s])"\Q$en\E"([),;\.\s\]\}])/$1"$pt"$2/g);
        $file_replacements += ($content =~ s/([=:,(\[\{\s])'\Q$en\E'([),;\.\s\]\}])/$1'$pt'$2/g);
    }

    if ($content ne $original) {
        open(my $out, '>:encoding(UTF-8)', $file) or do {
            warn "Nao foi possivel escrever $file: $!\n";
            next;
        };
        print $out $content;
        close $out;
        $files_modified++;
        $total_replacements += $file_replacements;
    }
}

print "Concluido. $files_modified arquivos modificados, $total_replacements substituicoes aplicadas.\n";
