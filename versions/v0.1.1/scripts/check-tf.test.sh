#!/usr/bin/env bash
# Vermelho primeiro do gate check-tf.sh. Cada fixture é um mini-repo Terraform com UM defeito.
#
# EXCEÇÃO DECLARADA (piso da schematize-shell, strict mode): harness de teste roda `set -u` sem `-e`
# — precisa continuar depois de um caso vermelho para reportar todos, em vez de parar no primeiro.
set -u
AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
G="$AQUI/check-tf.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP:?}"' EXIT INT TERM
ok=0; fail=0
D=""

# novo <nome>: cria o diretório do caso. f <caminho>: grava stdin em $D/<caminho>.
novo() { D="$TMP/$1"; mkdir -p "$D"; NOME="$1"; }
f() { mkdir -p "$(dirname "$D/$1")"; cat >"$D/$1"; }
# esperar <exit> <agulha>: roda o gate no caso atual e confere exit e trecho da saída.
esperar() {
  local esp="$1" agulha="$2" saida rc
  saida="$(bash "$G" "$D" 2>&1)"; rc=$?
  if [ "$rc" != "$esp" ]; then echo "  ✖ $NOME: exit $rc, esperado $esp"; sed 's/^/      /' <<<"$saida"; fail=$((fail+1)); return; fi
  if [ -n "$agulha" ] && ! grep -qF -- "$agulha" <<<"$saida"; then echo "  ✖ $NOME: exit certo, saída sem \"$agulha\""; sed 's/^/      /' <<<"$saida"; fail=$((fail+1)); return; fi
  echo "  ✔ $NOME"; ok=$((ok+1))
}

# Raiz mínima VÁLIDA (base dos casos): backend remoto, versão, provider pinado, lock multiplataforma.
raiz_boa() { # raiz_boa <subdir>
  f "$1/main.tf" <<'FIX'
terraform {
  required_version = ">= 1.9.0, < 2.0.0"
  backend "s3" {
    bucket       = "b"
    key          = "k"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.70"
    }
  }
}
provider "hcloud" {}
resource "hcloud_firewall" "fw" {
  name = "fw"
}
FIX
  f "$1/.terraform.lock.hcl" <<'FIX'
provider "registry.opentofu.org/hetznercloud/hcloud" {
  version     = "1.70.0"
  constraints = "~> 1.70"
  hashes = [
    "h1:aaaa",
    "h1:bbbb",
    "zh:cccc",
  ]
}
FIX
}

echo "== verde de partida =="
novo verde; raiz_boa envs/prd
esperar 0 "no piso"

echo "== nada para verificar =="
novo vazio; mkdir -p "$D"; echo "x" >"$D/README.md"
esperar 2 "nada para verificar"

echo "== backend =="
novo backend-ausente; raiz_boa envs/prd
f envs/prd/main.tf <<'FIX'
terraform {
  required_version = ">= 1.9.0"
  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.70"
    }
  }
}
resource "hcloud_firewall" "fw" {
  name = "fw"
}
FIX
esperar 1 "backend-ausente"

novo backend-local; raiz_boa envs/hml
f envs/hml/main.tf <<'FIX'
terraform {
  required_version = ">= 1.9.0"
  backend "local" {
    path = "terraform.tfstate"
  }
  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.70"
    }
  }
}
resource "hcloud_firewall" "fw" {
  name = "fw"
}
FIX
esperar 1 "backend-local"

novo backend-local-waiver; raiz_boa envs/dev
f envs/dev/main.tf <<'FIX'
# tf-ok: backend-ausente raiz de laboratório descartável, sem dado
terraform {
  required_version = ">= 1.9.0"
  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.70"
    }
  }
}
resource "hcloud_firewall" "fw" {
  name = "fw"
}
FIX
esperar 0 "no piso"

echo "== versionamento =="
novo sem-required-version; raiz_boa envs/prd
f envs/prd/main.tf <<'FIX'
terraform {
  backend "s3" {
    bucket = "b"
  }
  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.70"
    }
  }
}
resource "hcloud_firewall" "fw" {
  name = "fw"
}
FIX
esperar 1 "required-version"

novo provider-sem-version; raiz_boa envs/prd
f envs/prd/main.tf <<'FIX'
terraform {
  required_version = ">= 1.9.0"
  backend "s3" {
    bucket = "b"
  }
  required_providers {
    hcloud = {
      source = "hetznercloud/hcloud"
    }
  }
}
resource "hcloud_firewall" "fw" {
  name = "fw"
}
FIX
esperar 1 "provider-sem-pin"

novo provider-forma-legada; raiz_boa envs/prd
f envs/prd/main.tf <<'FIX'
terraform {
  required_version = ">= 1.9.0"
  backend "s3" {
    bucket = "b"
  }
  required_providers {
    hcloud = "~> 1.70"
  }
}
resource "hcloud_firewall" "fw" {
  name = "fw"
}
FIX
esperar 1 "forma legada"

novo provider-sem-teto; raiz_boa envs/prd
f envs/prd/main.tf <<'FIX'
terraform {
  required_version = ">= 1.9.0"
  backend "s3" {
    bucket = "b"
  }
  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = ">= 1.50.0"
    }
  }
}
resource "hcloud_firewall" "fw" {
  name = "fw"
}
FIX
esperar 1 "provider-sem-teto"

novo lock-ausente; raiz_boa envs/prd; rm "$D/envs/prd/.terraform.lock.hcl"
esperar 1 "lock-ausente"

novo lock-uma-plataforma; raiz_boa envs/prd
f envs/prd/.terraform.lock.hcl <<'FIX'
provider "registry.opentofu.org/hetznercloud/hcloud" {
  version     = "1.70.0"
  constraints = "~> 1.70"
  hashes = [
    "h1:aaaa",
    "zh:cccc",
    "zh:dddd",
  ]
}
FIX
esperar 1 "lock-sem-multiplataforma"

echo "== segredo =="
novo segredo-no-tf; raiz_boa envs/prd
f envs/prd/db.tf <<'FIX'
resource "hcloud_firewall" "db" {
  name = "db"
}
locals {
  db_password = "hunter2-troque-me"
}
FIX
esperar 1 "segredo-literal"

novo segredo-no-tfvars; raiz_boa envs/prd
f envs/prd/prd.tfvars <<'FIX'
ssh_key_ids  = [1]
api_token    = "abcdef0123456789"
FIX
esperar 1 "segredo-literal"

novo segredo-chave-aws; raiz_boa envs/prd
f envs/prd/x.tf <<'FIX'
locals {
  chave = "AKIAABCDEFGHIJKLMNOP"
}
FIX
esperar 1 "formato de chave conhecida"

novo segredo-default-variavel; raiz_boa envs/prd
f envs/prd/variables.tf <<'FIX'
variable "db_password" {
  type      = string
  default   = "troque"
  sensitive = true
}
FIX
esperar 1 "default literal"

novo segredo-waiver; raiz_boa envs/prd
f envs/prd/x.tf <<'FIX'
locals {
  # tf-ok: valor público de exemplo da doc do provedor, não é credencial
  api_token = "exemplo-publico-1234"
}
FIX
esperar 0 "no piso"

novo ref-a-variavel-nao-e-literal; raiz_boa envs/prd
f envs/prd/x.tf <<'FIX'
variable "db_password" {
  type      = string
  sensitive = true
}
locals {
  db_password = var.db_password
  secret_name = "nome-do-segredo-no-cofre"
}
FIX
esperar 0 "no piso"

echo "== variável/output sensível =="
novo variavel-sem-sensitive; raiz_boa envs/prd
f envs/prd/variables.tf <<'FIX'
variable "db_password" {
  type = string
}
FIX
esperar 1 "variavel-sensivel"

novo output-sem-sensitive; raiz_boa envs/prd
f envs/prd/outputs.tf <<'FIX'
output "api_token" {
  value = "x"
}
FIX
esperar 1 "output-sensivel"

novo variavel-ephemeral-ok; raiz_boa envs/prd
f envs/prd/variables.tf <<'FIX'
variable "db_password" {
  type      = string
  ephemeral = true
}
FIX
esperar 0 "no piso"

echo "== state/plan versionado =="
novo tfstate-no-repo; raiz_boa envs/prd
echo '{"version":4}' >"$D/envs/prd/terraform.tfstate"
esperar 1 "state-versionado"

novo tfplan-no-repo; raiz_boa envs/prd
echo 'x' >"$D/envs/prd/plano.tfplan"
esperar 1 "state-versionado"

echo "== recurso crítico =="
novo critico-count-sem-prevent; raiz_boa envs/prd
f envs/prd/db.tf <<'FIX'
resource "aws_db_instance" "banco" {
  count          = 2
  instance_class = "db.t3.micro"
}
FIX
esperar 1 "critico-sem-prevent-destroy"

novo critico-foreach-sem-prevent; raiz_boa envs/prd
f envs/prd/vol.tf <<'FIX'
resource "hcloud_volume" "dados" {
  for_each = toset(["a", "b"])
  name     = each.key
  size     = 10
}
FIX
esperar 1 "critico-sem-prevent-destroy"

novo critico-count-com-prevent; raiz_boa envs/prd
f envs/prd/db.tf <<'FIX'
resource "aws_db_instance" "banco" {
  count          = 2
  instance_class = "db.t3.micro"
  lifecycle {
    prevent_destroy = true
  }
}
FIX
esperar 0 "no piso"

novo critico-simples-so-avisa; raiz_boa envs/prd
f envs/prd/vol.tf <<'FIX'
resource "hcloud_volume" "dados" {
  name = "d"
  size = 10
}
FIX
esperar 0 "AVISO"

echo "== módulo =="
novo provider-em-modulo-filho; raiz_boa envs/prd
f modules/servidor/main.tf <<'FIX'
terraform {
  required_version = ">= 1.9.0"
  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = ">= 1.50.0"
    }
  }
}
provider "hcloud" {
  token = "x"
}
resource "hcloud_firewall" "fw" {
  name = "fw"
}
FIX
esperar 1 "provider-em-modulo"

novo modulo-bom-sem-lock-nem-backend; raiz_boa envs/prd
f modules/servidor/main.tf <<'FIX'
terraform {
  required_version = ">= 1.9.0"
  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = ">= 1.50.0, < 2.0.0"
    }
  }
}
resource "hcloud_firewall" "fw" {
  name = "fw"
}
FIX
esperar 0 "no piso"

echo "== heredoc/comentário não enganam =="
novo comentario-nao-conta; raiz_boa envs/prd
f envs/prd/x.tf <<'FIX'
# db_password = "isto é um comentário, não um segredo"
// api_token = "idem"
FIX
esperar 0 "no piso"

echo
echo "check-tf.test: $ok ok, $fail falha(s)"
[ "$fail" -eq 0 ]
