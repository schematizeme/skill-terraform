#!/usr/bin/env bash
# check-tf.sh — gate estático da schematize-terraform. Funciona SEM terraform/tofu instalado.
#
# Motivo: o que mais machuca em IaC (state local, provider solto, segredo no tfvars, recurso
# de dados que some por mudança de índice) é visível no texto do repo, antes de qualquer plan.
# Como funciona: percorre os diretórios com *.tf, classifica cada um como RAIZ (envs/, stacks/…)
# ou MÓDULO (caminho com /modules/) e aplica as regras abaixo com awk (sem parser HCL: heurística
# de blocos de topo; o que ela não prova, o tflint/validate provam).
# Entrada: $1 = diretório (default .). Env: TF_GATE_TEXTO=1 desliga cor (já é sem cor).
# Saída: achados `arquivo:linha: [ERRO|AVISO regra] mensagem`.
#        exit 0 passa · 1 reprova · 2 NADA para verificar (não é aprovação).
#
# Regras (id): backend-ausente · backend-local · required-version · provider-sem-pin ·
#   provider-sem-teto · lock-ausente · lock-sem-multiplataforma · segredo-literal ·
#   state-versionado · critico-sem-prevent-destroy · provider-em-modulo · variavel-sensivel ·
#   output-sensivel.
# Waiver rastreável: `# tf-ok: <motivo>` na linha ou na de cima (regras de linha/bloco);
#   `# tf-ok: <regra-id> <motivo>` em qualquer .tf do diretório (regras de diretório).
set -euo pipefail

RAIZ="${1:-.}"
[ -d "$RAIZ" ] || { echo "check-tf: '$RAIZ' não é diretório" >&2; exit 2; }

ACHADOS="$(mktemp)"
trap 'rm -f "$ACHADOS"' EXIT INT TERM
: >"$ACHADOS"

emit() { # emit <arquivo> <linha> <ERRO|AVISO> <regra> <msg>
  printf '%s:%s: [%s %s] %s\n' "$1" "$2" "$3" "$4" "$5" >>"$ACHADOS"
}

# Programa awk por arquivo .tf: blocos de topo + regras de linha.
# Variáveis: -v arq= -v modulo=0|1. Emite achados em stdout e linhas META para o agregador.
AWK_TF='
function strip(s) { gsub(/"([^"\\]|\\.)*"/, "\"\"", s); return s }
function nc(s,   t) { t = s; sub(/^[ \t]*(#|\/\/).*$/, "", t); return t }
function waived(l, p) { return (l ~ /tf[-]ok:/ || p ~ /tf[-]ok:/) }
function meta(k) { printf "META\t%s\t%s\n", k, arq }
function out(sev, rule, ln, msg) { printf "%s:%d: [%s %s] %s\n", arq, ln, sev, rule, msg }
function nome_sensivel(n) { return (n ~ /(password|passwd|secret|token|api_key|apikey|private_key|credential|passphrase|secret_key|access_key)s?$/) }
function critico(t) {
  return (t ~ /^(aws_db_instance|aws_rds_cluster|aws_s3_bucket|aws_dynamodb_table|aws_kms_key|aws_ebs_volume|aws_efs_file_system|hcloud_volume|hcloud_primary_ip|hcloud_floating_ip|cloudflare_zone|cloudflare_r2_bucket|google_sql_database_instance|google_storage_bucket|azurerm_mssql_database|azurerm_storage_account|azurerm_key_vault|github_repository)$/)
}
function fecha_bloco(   i, n, linhas, l, rp, depth2, pname, pbody, pstart, ptxt) {
  if (btype == "variable" && nome_sensivel(bl1)) {
    if (!bsens && !waived(bhdr, bprev)) out("ERRO", "variavel-sensivel", bstart, "variable \"" bl1 "\" parece segredo e não tem sensitive = true (nem ephemeral = true)")
    if (bdefault_lit && !waived(bhdr, bprev)) out("ERRO", "segredo-literal", bstart, "variable \"" bl1 "\" tem default literal: segredo nunca em código")
  }
  if (btype == "output" && nome_sensivel(bl1)) {
    if (!bsens && !waived(bhdr, bprev)) out("ERRO", "output-sensivel", bstart, "output \"" bl1 "\" parece segredo e não tem sensitive = true (nem ephemeral = true)")
  }
  if (btype == "provider" && modulo == 1) {
    if (!waived(bhdr, bprev)) out("ERRO", "provider-em-modulo", bstart, "provider \"" bl1 "\" configurado dentro de módulo filho: a raiz configura, o módulo só declara required_providers")
  }
  if (btype == "resource" && critico(bl1)) {
    if (!bprevent && !waived(bhdr, bprev)) {
      if (bmulti) out("ERRO", "critico-sem-prevent-destroy", bstart, "resource \"" bl1 "\" \"" bl2 "\" crítico com count/for_each e sem lifecycle { prevent_destroy = true } (mudar o índice destrói o dado)")
      else out("AVISO", "critico-sem-prevent-destroy", bstart, "resource \"" bl1 "\" \"" bl2 "\" crítico sem prevent_destroy")
    }
  }
  if (btype == "terraform") {
    meta("tem_terraform")
    if (btxt ~ /required_version[ \t]*=/) meta("required_version")
    if (btxt ~ /backend[ \t]+"local"/) meta("backend_local")
    else if (btxt ~ /backend[ \t]+"[a-z0-9_]+"/) meta("backend_remoto")
    if (btxt ~ /required_providers[ \t]*\{/) meta("required_providers")
    # required_providers: cada provider precisa de version; raiz exige teto
    n = split(btxt, linhas, "\n"); rp = 0; depth2 = 0; pname = ""
    for (i = 1; i <= n; i++) {
      l = nc(linhas[i]); ls = strip(l)
      if (rp == 0) { if (ls ~ /required_providers[ \t]*\{/) { rp = 1; depth2 = 0 } continue }
      if (depth2 == 0 && ls ~ /^[ \t]*[A-Za-z0-9_-]+[ \t]*=[ \t]*\{/) {
        pname = l; sub(/^[ \t]*/, "", pname); sub(/[ \t]*=.*/, "", pname); pbody = ""; pstart = bstart + i - 1; ptxt = ""
      } else if (depth2 == 0 && ls ~ /^[ \t]*[A-Za-z0-9_-]+[ \t]*=[ \t]*"/) {
        pname = l; sub(/^[ \t]*/, "", pname); sub(/[ \t]*=.*/, "", pname)
        if (!waived(linhas[i], linhas[i-1])) out("ERRO", "provider-sem-pin", bstart + i - 1, "provider \"" pname "\" na forma legada (string): use { source, version }")
      }
      if (pname != "" && depth2 >= 1) ptxt = ptxt "\n" l
      o = gsub(/\{/, "{", ls); c = gsub(/\}/, "}", ls); depth2 += o - c
      if (depth2 < 0) { rp = 0; continue }
      if (pname != "" && depth2 == 0 && ptxt != "") {
        if (ptxt !~ /version[ \t]*=/) { if (!waived(linhas[pstart - bstart + 1], linhas[pstart - bstart])) out("ERRO", "provider-sem-pin", pstart, "provider \"" pname "\" sem version em required_providers") }
        else if (modulo == 0) {
          v = ptxt; sub(/.*version[ \t]*=[ \t]*"/, "", v); sub(/".*/, "", v)
          if (v !~ /(~>|<)/ && v ~ />/) { if (!waived(linhas[pstart - bstart + 1], linhas[pstart - bstart])) out("ERRO", "provider-sem-teto", pstart, "provider \"" pname "\" com version \"" v "\" sem teto: na raiz use ~> ou intervalo fechado") }
        }
        pname = ""; ptxt = ""
      }
    }
  }
  if (btype == "provider" && modulo == 0) meta("provider_usado")
  if (btype == "resource" || btype == "module" || btype == "data") meta("provider_usado")
}
BEGIN { depth = 0; btype = "" }
{
  raw = $0
  # --- regra de linha: segredo literal (vale dentro e fora de bloco) ---
  lc = nc(raw)
  if (lc != "" && !waived(raw, prev)) {
    if (lc ~ /^[ \t]*[A-Za-z0-9_]*(password|passwd|secret|token|api_key|apikey|private_key|passphrase|secret_key|access_key|client_secret|secret_string|credentials?)[ \t]*=[ \t]*"[^"$]+"/) {
      out("ERRO", "segredo-literal", NR, "atributo de segredo com valor literal: use cofre/variável de ambiente/ephemeral, nunca texto no código")
    } else if (lc ~ /AKIA[0-9A-Z]{16}/ || lc ~ /-----BEGIN [A-Z ]*PRIVATE KEY-----/ || lc ~ /gh[pousr]_[A-Za-z0-9]{30,}/ || lc ~ /xox[abp]-[0-9A-Za-z-]{10,}/) {
      out("ERRO", "segredo-literal", NR, "credencial no formato de chave conhecida no texto")
    }
  }
  if (isvars) { prev = raw; next }
  s = strip(lc)
  if (depth == 0) {
    if (s ~ /^[ \t]*(resource|variable|output|provider|terraform|module|data|locals)[ \t]*("[^"]*"[ \t]*)*\{/) {
      btype = s; sub(/^[ \t]*/, "", btype); sub(/[ \t"{].*/, "", btype)
      bl1 = ""; bl2 = ""
      t = lc; q = split(t, partes, "\"")
      if (q >= 2) bl1 = partes[2]
      if (q >= 4) bl2 = partes[4]
      bstart = NR; bhdr = raw; bprev = prev; btxt = ""
      bsens = 0; bmulti = 0; bprevent = 0; bdefault_lit = 0
    }
  }
  if (btype != "") {
    btxt = btxt raw "\n"
    if (depth == 1) {
      if (lc ~ /^[ \t]*(count|for_each)[ \t]*=/) bmulti = 1
      if (lc ~ /^[ \t]*(sensitive|ephemeral)[ \t]*=[ \t]*true/) bsens = 1
      if (btype == "variable" && lc ~ /^[ \t]*default[ \t]*=[ \t]*"[^"$]+"/) bdefault_lit = 1
    }
    if (lc ~ /prevent_destroy[ \t]*=[ \t]*true/) bprevent = 1
    o = gsub(/\{/, "{", s); c = gsub(/\}/, "}", s)
    depth += o - c
    if (depth <= 0) { depth = 0; fecha_bloco(); btype = "" }
  }
  prev = raw
}
'

# --- coleta de arquivos -------------------------------------------------------------
LISTA="$(mktemp)"
trap 'rm -f "$ACHADOS" "$LISTA"' EXIT INT TERM
find "$RAIZ" \( -name .git -o -name .terraform -o -name node_modules -o -name versions \) -prune -o \
  -type f \( -name '*.tf' -o -name '*.tfvars' \) -print | LC_ALL=C sort >"$LISTA"

if [ ! -s "$LISTA" ]; then
  echo "check-tf: nenhum .tf/.tfvars em '$RAIZ' — nada para verificar (exit 2, não é aprovação)" >&2
  exit 2
fi

eh_modulo() { case "/$1/" in */modules/*) return 0 ;; *) return 1 ;; esac }

# --- por diretório ------------------------------------------------------------------
DIRS="$(while IFS= read -r f; do case "$f" in *.tf) dirname "$f" ;; esac; done <"$LISTA" | LC_ALL=C sort -u)"

dir_waived() { # dir_waived <dir> <regra>
  local d="$1" r="$2" f
  for f in "$d"/*.tf; do
    [ -e "$f" ] || continue
    grep -qE "tf-ok:[[:space:]]*$r([[:space:]]|\$)" "$f" && return 0
  done
  return 1
}

# Pass 1: awk por arquivo (achados de bloco/linha + META por diretório)
while IFS= read -r f; do
  d="$(dirname "$f")"
  mod=0; eh_modulo "$d" && mod=1
  isv=0; case "$f" in *.tfvars) isv=1 ;; esac
  awk -v arq="$f" -v modulo="$mod" -v isvars="$isv" "$AWK_TF" "$f" >>"$ACHADOS.raw.$$" 2>/dev/null || true
done <"$LISTA"
trap 'rm -f "$ACHADOS" "$LISTA" "$ACHADOS.raw.$$"' EXIT INT TERM
[ -e "$ACHADOS.raw.$$" ] || : >"$ACHADOS.raw.$$"
grep -v $'^META\t' "$ACHADOS.raw.$$" >>"$ACHADOS" || true

# Pass 2: regras de diretório (precisam do agregado de META por arquivo).
meta_dir() { # meta_dir <dir> <chave> -> 0 se algum .tf do dir emitiu a chave
  awk -F'\t' -v d="$1" -v k="$2" '
    $1 == "META" && $2 == k { f = $3; sub(/\/[^\/]*$/, "", f); if (f == d) achou = 1 }
    END { exit !achou }' "$ACHADOS.raw.$$"
}

while IFS= read -r d; do
  [ -n "$d" ] || continue
  mod=0; eh_modulo "$d" && mod=1
  meta_dir "$d" provider_usado || meta_dir "$d" tem_terraform || continue   # diretório só de variáveis/locals: ignora
  if [ "$mod" = 0 ]; then
    if ! meta_dir "$d" backend_remoto && ! meta_dir "$d" backend_local; then
      dir_waived "$d" backend-ausente || emit "$d" 1 ERRO backend-ausente "raiz sem bloco backend: o state ficaria LOCAL (sem lock, sem backup, sem time). Declare backend remoto com lock"
    fi
    if meta_dir "$d" backend_local; then
      dir_waived "$d" backend-local || {
        linha="$(grep -n 'backend[[:space:]]*"local"' "$d"/*.tf 2>/dev/null | head -1 | cut -d: -f1-2 || true)"
        emit "$d" "${linha:-1}" ERRO backend-local "backend \"local\" em código de ambiente: state em disco de laptop/CI não tem lock nem time"
      }
    fi
  fi
  if ! meta_dir "$d" required_version; then
    dir_waived "$d" required-version || emit "$d" 1 ERRO required-version "sem required_version no bloco terraform {} (versão da CLI não fixada)"
  fi
  if ! meta_dir "$d" required_providers; then
    dir_waived "$d" provider-sem-pin || emit "$d" 1 ERRO provider-sem-pin "sem required_providers com version (provider solto sobe sem aviso)"
  fi
  if [ "$mod" = 0 ] && meta_dir "$d" required_providers; then
    lock="$d/.terraform.lock.hcl"
    if [ ! -f "$lock" ]; then
      dir_waived "$d" lock-ausente || emit "$d" 1 ERRO lock-ausente ".terraform.lock.hcl ausente: commite-o (reprodutibilidade e supply chain dos providers)"
    else
      # >= 2 hashes h1: por provider = lock multiplataforma (providers lock -platform=...)
      awk -v arq="$lock" '
        /^provider "/ { if (nome != "" && h1 < 2) printf "%s:%d: [ERRO lock-sem-multiplataforma] provider %s com %d hash h1 (rode providers lock -platform=linux_amd64 -platform=linux_arm64 -platform=darwin_arm64 -platform=darwin_amd64 -platform=windows_amd64)\n", arq, ln, nome, h1; nome=$2; gsub(/"/, "", nome); h1=0; ln=NR }
        /"h1:/ { h1++ }
        END { if (nome != "" && h1 < 2) printf "%s:%d: [ERRO lock-sem-multiplataforma] provider %s com %d hash h1 (rode providers lock -platform=linux_amd64 -platform=linux_arm64 -platform=darwin_arm64 -platform=darwin_amd64 -platform=windows_amd64)\n", arq, ln, nome, h1 }
      ' "$lock" >>"$ACHADOS"
    fi
  fi
done <<<"$DIRS"

# --- state / plan versionado ------------------------------------------------------------
# Em repo git usa o índice (o que está VERSIONADO); fora de git, o que existe na árvore.
if git -C "$RAIZ" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  TOPO="$(git -C "$RAIZ" rev-parse --show-toplevel)"
  ARQS="$(git -C "$RAIZ" ls-files -- '*.tfstate' '*.tfstate.*' '*.tfplan' 'tfplan' 'tfplan.json' 2>/dev/null | sed "s|^|$TOPO/|" || true)"
else
  ARQS="$(find "$RAIZ" \( -name .git -o -name .terraform \) -prune -o -type f \( -name '*.tfstate' -o -name '*.tfstate.*' -o -name '*.tfplan' -o -name tfplan -o -name tfplan.json \) -print)"
fi
if [ -n "$ARQS" ]; then
  while IFS= read -r a; do
    [ -n "$a" ] || continue
    emit "$a" 1 ERRO state-versionado "state/plan no repositório: contém segredo em claro. Remova do histórico, rotacione o que vazou, e ponha no .gitignore"
  done <<<"$ARQS"
fi

# --- relatório ---------------------------------------------------------------------------
ERROS="$(grep -c '\[ERRO ' "$ACHADOS" || true)"
AVISOS="$(grep -c '\[AVISO ' "$ACHADOS" || true)"
if [ -s "$ACHADOS" ]; then LC_ALL=C sort -u "$ACHADOS"; fi
if [ "$ERROS" -gt 0 ]; then
  echo "check-tf: REPROVADO — $ERROS erro(s), $AVISOS aviso(s)." >&2
  veredito=1
else
  echo "check-tf: no piso — 0 erro(s), $AVISOS aviso(s)."
  veredito=0
fi
exit "$veredito"
