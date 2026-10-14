---
description: schematize-terraform — revisa um repo IaC (OpenTofu/Terraform) contra o piso: roda o gate e as ferramentas, depois lê o que a máquina não lê
argument-hint: "[diretório do repo IaC]"
---

# /tf-review — IaC é código de produção com credencial de produção

## 1. A máquina primeiro

```bash
bash .claude/skills/schematize-terraform/scripts/check-tf.sh "${ARGUMENTS:-.}"   # o piso da casa
```
`0` passa · `1` reprova · `2` **nada para verificar** — que não é aprovação.

O gate cobre: backend ausente/local em raiz, `required_version`, provider sem `version` (ou sem
teto na raiz, ou na forma legada), lock ausente ou sem hashes multiplataforma, segredo literal em
`.tf`/`.tfvars`/`default`, `*.tfstate`/`*.tfplan` versionado, recurso crítico com `count`/`for_each`
sem `prevent_destroy`, `provider {}` em módulo filho, variável/saída de segredo sem `sensitive`.
Waiver: `# tf-ok: <motivo>` (linha ou bloco) e `# tf-ok: <regra> <motivo>` (diretório).

Depois, **se as ferramentas existirem** (diga quais faltaram, não finja):
```bash
tofu fmt -check -recursive          # ou terraform
for d in envs/*/; do (cd "$d" && tofu init -backend=false -input=false && tofu validate); done
tflint --recursive --config "$PWD/.tflint.hcl"
checkov -d . --framework terraform --quiet --compact   # ou: trivy config .
conftest verify --policy policy/                       # a política tem teste
```

## 2. Depois, o que a máquina não lê

- **Workspace separando ambientes?** `terraform.workspace` num `condition` é o cheiro. Ambientes
  são raízes (`references/estrutura.md` §2).
- **Raio de dano:** o que perco se ESTE state sumir? Está partido por ciclo de vida (rede, dados, app)?
- **Credencial:** plan com leitura, apply com escrita, OIDC, nada de chave estática; token do
  provider por variável de ambiente, não por `var`.
- **Segredo no state:** quais atributos persistem o segredo? Há `ephemeral`/`*_wo` disponível no
  provider? O state do OpenTofu está cifrado (`enforced`)?
- **Módulo:** `validation` rejeita o perigoso? default seguro? saída mínima? versão pinada ao consumir?
- **Destrutivo:** todo `prevent_destroy` onde há dado? `for_each` com chave estável?
- **Fluxo:** o CI aplica plan salvo? há *environment* com revisores em prd? alguém consegue
  `apply` do laptop em prd?
- **Drift:** existe plan agendado com credencial somente leitura e destino do alerta?
- **Refactor:** `moved`/`import`/`removed` em vez de `state mv`.
- **Tags/labels** obrigatórias; política (`conftest`) cobrindo o resto.
- **Efeito externo:** domínio, e-mail ou webhook de hml/dev apontando para o mundo real?

## 3. Feche

Achado vira correção no mesmo PR ou item de checklist com dono. O vermelho do próprio gate:
`bash scripts/check-tf.test.sh`.
