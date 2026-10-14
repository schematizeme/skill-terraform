# Changelog — schematize-terraform

Todas as mudanças relevantes deste pacote, no formato [Keep a Changelog](https://keepachangelog.com/pt-BR/1.1.0/),
com versionamento [SemVer](https://semver.org/lang/pt-BR/).

## [0.1.1] — 2026-10-14
Integração ao catálogo (grafo, skills.json, herdados) e correção do texto de precedência herdado.

### Alterado
- Blocos herdados ressincronizados com a `schematize-engineering` v0.27.0 (`tools/sync-herdados.mjs`): orquestração com a regra de imagem (nunca pelo Claude; detecta Codex/Gemini e pergunta ao usuário qual usar, Codex como sugestão) e `schematize overdev delegar` (comando do app) no lugar do falso nome de skill `schematize-overdev`.
- Bloco "Precedência e herança" passa à variante `dominio`: o texto antigo dizia que os comandos `/tf-*` "cobrem só o piso da linguagem", o que é falso para skill de domínio/ferramenta.

## [0.1.0] — 2026-10-14
Primeira versão. A `schematize-infra` trata IaC como princípio agnóstico de ferramenta, mas o
Terraform/OpenTofu tem armadilhas próprias que viram incidente (state local, provider solto,
workspace como "ambiente", segredo no state, apply da máquina do dev) e não tinham dono nem gate.

### Adicionado
- `SKILL.md` com 14 pisos, fronteira explícita com `schematize-infra` e mapa de references.
- `references/`: `ferramenta` (OpenTofu por default por ser MPL, Terraform por ADR por ser BUSL;
  diferenças verificadas: criptografia de state, `enabled`, `-exclude`, `ephemeral`/write-only),
  `estrutura` (por que workspace não separa prd de hml), `state`, `versoes-e-modulos`, `segredos`,
  `fluxo`, `qualidade`, `providers` (Hetzner, Cloudflare v5, GitHub, AWS) e `stack-versoes`.
- `scripts/check-tf.sh` + `check-tf.test.sh`: 13 regras estáticas, sem depender de `tofu`/`terraform`,
  29 casos (vermelhos plantados), waiver `# tf-ok:`.
- `assets/`: esqueleto de repo validado em OpenTofu 1.13.1 e Terraform 1.16.5 (com lock files
  multiplataforma reais e teste de módulo com `mock_provider`), backends de exemplo, `.tflint.hcl`,
  política Rego com teste, workflows de CI e de drift com actions pinadas por SHA.
- Comandos: `tf-help`, `tf-load`, `tf-review`, `tf-plan`, `tf-module`, `tf-drift`, `tf-import`,
  `tf-claude`, `tf-handoff`, `tf-cc`.

### Não verificado
- `plan`/`apply` contra provedor real, backend S3 real, `use_lockfile` em S3-compatível e o
  workflow rodando no GitHub (ver `references/stack-versoes.md`).
