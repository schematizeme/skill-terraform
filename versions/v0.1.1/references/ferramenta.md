# Qual ferramenta: OpenTofu por default, Terraform por ADR

> A casa escreve IaC em HCL e roda com **OpenTofu** salvo decisão escrita em contrário. Este arquivo
> é a política e o *porquê*; versões e datas ficam no anexo volátil `stack-versoes.md`.

## 1. A política

1. **Default: OpenTofu** (`tofu`). Licença **MPL-2.0** (open source de verdade), governança aberta,
   sem cláusula de uso concorrente. O código HCL que a casa escreve **não depende de licença
   restritiva** para ser executado.
2. **Terraform (`terraform`) exige ADR** (`schematize-docs → adr`) com o motivo concreto. Motivos
   que a casa aceita: o cliente já opera Terraform Cloud/HCP ou Terraform Enterprise e a
   migração não paga o custo; um provider ou integração só tem suporte oficial no Terraform; uma
   exigência contratual nomeia a ferramenta.
3. **Uma ferramenta por repositório.** O `.terraform.lock.hcl` carrega o *registry* de origem de
   cada provider (`registry.opentofu.org/...` vs `registry.terraform.io/...`): trocar de
   ferramenta no meio muda os hashes do lock. Escolha, escreva no README do repo e no CI.
4. **Código portável por construção.** Escreva o subconjunto comum de HCL sempre que o recurso
   exclusivo não pagar o custo de prender o repo a uma ferramenta. O que é exclusivo de um lado
   (ver §3) entra **declarado**, com comentário e, se for estrutural, com ADR.

## 2. Por que OpenTofu é o default (e o que não é razão)

| Razão | Peso |
|---|---|
| Licença: Terraform passou a **BUSL-1.1** (a partir da 1.6; a 1.5.x foi a última em MPL). A BUSL restringe uso em produto que concorra com o fornecedor — risco jurídico para quem vende plataforma/PaaS/ferramenta de infra | alto |
| **State encryption nativo** no cliente (OpenTofu 1.7+): o state e o plan saem cifrados para qualquer backend | alto |
| Registry e mirror abertos; versões LTS de suporte declarado | médio |
| Recursos próprios úteis (ver §3): `enabled`, `-exclude`, variáveis em backend/módulo `source`, `-lint` | médio |
| "É mais barato" | **não é razão**: ambos são grátis para rodar |
| "Tem mais comunidade" | **não é razão**: o ecossistema (providers, módulos) é compartilhado |

## 3. Diferenças que mudam o desenho (verificado — fontes em `stack-versoes.md`)

| Tema | OpenTofu | Terraform |
|---|---|---|
| Licença da CLI | MPL-2.0 | BUSL-1.1 |
| **State/plan encryption** | **sim**, `terraform { encryption { ... } }` (1.7+) | **não** (só criptografia do backend/servidor) |
| Valores efêmeros (`ephemeral` var/output/resource) | sim (1.11+) | sim (1.10+) |
| Argumentos **write-only** (`*_wo`) | sim (1.11+) | sim (1.11+) |
| `enabled` em `lifecycle` (0 ou 1 instância, no lugar de `count = x ? 1 : 0`) | **sim** (1.11+) | não |
| `-exclude`/`-exclude-file` no plan/apply | sim (1.9+/1.10+) | não |
| Variáveis/locals em `backend` e em `source` de módulo | sim (1.8+) | não |
| Bloco `import`, `moved`, `removed`, `terraform test`/`tofu test`, `mock_provider` | sim | sim |
| `actions` (bloco top-level de ações do provider) | não <!-- reverificar --> | sim (1.14+) |
| Lint integrado | `-lint` (1.13+, experimental) | não |

Regra de uso: **nunca** dependa de recurso exclusivo sem declarar. Um módulo reutilizável que usa
`enabled` ou `encryption` só roda em OpenTofu e deve dizer isso no README e em `required_version`.

## 4. Como a casa trata a migração

- **Terraform ≤ 1.5.x → OpenTofu**: troca direta (state compatível). Rode `tofu init`, confira o
  `plan` vazio, regere o lock (`tofu providers lock` multiplataforma) e commite.
- **Terraform ≥ 1.6 → OpenTofu**: depende do que o state já usa; **teste em cópia** do state
  (`tofu plan` sem diff) antes de trocar o CI. Documentação oficial de migração do OpenTofu manda.
  <!-- reverificar: matriz de compatibilidade por versão do Terraform -->
- **OpenTofu → Terraform**: só por ADR; o state criptografado pelo OpenTofu **não** abre no
  Terraform — desligue a criptografia com migração planejada antes.

## 5. O que esta skill diz de "Terraform" vale para os dois

Daqui em diante, "Terraform" significa "Terraform **ou** OpenTofu"; os comandos aparecem com
`tofu` (default). Troque por `terraform` onde a ADR mandar. Onde só um dos lados tem o recurso, o
texto diz.
