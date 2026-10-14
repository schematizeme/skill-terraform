# Fluxo: plan, revisão, apply gated, drift, refatoração segura

## 1. O ciclo

```
PR  ->  fmt/validate/tflint/checkov/policy  ->  plan SALVO (artefato)  ->  revisão humana do plan
    ->  merge em main  ->  apply SÓ do plan aprovado (hml)  ->  apply (prd) atrás de aprovação
```

Pisos:
1. **`plan` antes de `apply`, sempre**, e o plan que se revisa é o plan que se aplica.
2. **Plan salvo como artefato**: `tofu plan -out=plano.tfplan`; o `apply` consome **esse arquivo**
   (`tofu apply plano.tfplan`). Sem `-auto-approve` em plan recalculado: entre o plan e o apply o
   mundo pode ter mudado, e o apply recalculado aplica algo que ninguém leu. Plan aplicado de
   state obsoleto é **recusado** pela ferramenta (isso é desejado).
3. **Apply de prd só pelo CI**, no *environment* protegido (revisores obrigatórios, só `main`).
   **Nunca `apply` local em prd.** Nem "só dessa vez". Emergência = break-glass (§3).
4. **hml antes de prd**, mesmo código. O que passou em hml sem ninguém olhar não prova nada em prd.
5. **Plan salvo é segredo em potencial**: retenção curta, repo privado, `encryption.plan` no OpenTofu.
6. **Um apply por vez por ambiente** (`concurrency` no CI sem cancelar no meio + lock do state).

## 2. Como se lê um plan (rito, `/tf-plan`)

Ordem de leitura:
1. **Resumo**: `N to add, N to change, N to destroy`. O número de `destroy` é a primeira coisa.
2. **Todo `destroy` e todo `must be replaced` (`-/+`)**: o que é? Tem dado? Por que o atributo
   mudou (`forces replacement`)? Recurso com estado (banco, volume, IP fixo, bucket, zona DNS)
   que será recriado é **alarme**, não detalhe.
3. **`known after apply` em campo que não deveria**: indica dependência trocada ou módulo
   reescrito.
4. **Mudança que você não escreveu** (`~` num recurso que o PR não tocou): é drift, ou bump de
   provider mudando default. Descubra antes de aprovar.
5. **Segurança**: abertura de firewall, política IAM ampla, bucket público, remoção de
   criptografia/proteção. Os gates pegam o óbvio; você pega o contexto.
6. **Custo**: recurso novo caro? (`infracost`, `references/qualidade.md` §6.)
7. **Aprovação**: quem aprova **não é** quem escreveu (em prd, 2 pessoas). Aprovar é afirmar
   "li o plan", não "li o diff do código".

Plan que o revisor não consegue ler (milhares de linhas): o PR está grande demais — divida por stack.

## 3. Break-glass (emergência)

Produção caiu e o pipeline não serve? Apply manual é **exceção auditada**: credencial de
emergência de uso único, dupla checagem, tudo registrado no archive (`schematize-archive`), e o
estado volta ao código **no mesmo dia** (a mudança manual vira PR). Estado divergente que sobrou
é drift (§4) e abre pendência.

## 4. Drift: o mundo mudou fora do código

- **Detecção agendada**: `plan -detailed-exitcode` diário por ambiente com credencial somente
  leitura (`assets/ci/github-actions-drift.yml`). Exit `2` = drift → abre issue. `1` = erro do job.
- **Causas**: console clicado, outro automatismo, o provedor alterou default, recurso apagado.
- **Resolução**: (a) o código está certo → `apply` traz o mundo de volta; (b) a mudança era
  legítima → **vira PR** e o drift some. Nunca "convive com o drift" nem "ignora o diff".
- **`ignore_changes`** é para atributo que *outro sistema legitimamente gere* (ex.: `desired_count`
  gerido por autoscaling); registre o motivo em comentário. Não use para calar drift incômodo.
- `plan -refresh-only` mostra só o que mudou no mundo (sem mudanças de código); `apply -refresh-only`
  atualiza o state sem tocar na infra — use depois de decidir que o mundo é a verdade.

## 5. Refatorar sem tocar no state à mão: `moved`, `import`, `removed`

`state mv`/`rm`/`import` por comando não passam por PR nem deixam trilha. Use os **blocos**:

```hcl
# Renomear/mover recurso ou módulo sem recriar (Terraform 1.1+, OpenTofu 1.6+)
moved {
  from = hcloud_server.app
  to   = module.app.hcloud_server.this
}

# Adotar recurso existente no state (Terraform 1.5+, OpenTofu 1.6+); com for_each desde 1.7
import {
  to = hcloud_firewall.base
  id = "123456"
}

# Tirar do state SEM destruir o objeto real (Terraform 1.7+, OpenTofu 1.7+)
removed {
  from = hcloud_server.legado
  lifecycle {
    destroy = false
  }
}
```

Rito: escreva o bloco no PR → `plan` mostra `will be moved/imported/removed from state` e
**nenhum destroy** → revisão → apply → **mantenha** o bloco por um ciclo de releases (módulos
publicados mantêm `moved` para quem atualiza depois) e remova quando todos os states migraram.
`plan -generate-config-out=gerado.tf` (import; confira se a sua versão suporta) gera o HCL de um recurso importado; revise
antes de adotar (vem com atributos computados e pode embutir segredo).

`terraform state mv/rm/import` por linha de comando só em recuperação, registrada.

## 6. Lifecycle

| Argumento | Quando |
|---|---|
| `prevent_destroy = true` | **todo** recurso com dado ou impossível de recriar (banco, volume, bucket, IP, zona DNS, chave KMS). Faz o plan que destruiria **falhar**. Para destruir de propósito: PR que remove a trava, revisado |
| `create_before_destroy = true` | recurso que não pode ficar fora do ar na troca (certificado, instância atrás de LB). Atenção a nomes únicos |
| `ignore_changes = [...]` | atributo gerido por outro sistema; com comentário do porquê. Nunca `all` |
| `replace_triggered_by = [...]` | forçar recriação quando outro recurso muda |
| `precondition`/`postcondition` | invariantes que o plano deve respeitar (ex.: "região permitida") |
| `enabled` (OpenTofu 1.11+) | 0/1 instância sem `count` |

`prevent_destroy` não protege contra `terraform destroy` de um **módulo removido do código**
(o recurso some da configuração, então a trava some junto). Para tirar do código sem destruir:
bloco `removed`. Para proteger de verdade o dado: também a proteção do provedor
(`delete_protection`, versionamento de bucket, backup) — `schematize-infra → resiliencia.md`.

## 7. Comandos que pedem cuidado

| Comando | Cuidado |
|---|---|
| `apply -auto-approve` | só em ambiente efêmero. Em hml/prd, só aplicando plan salvo aprovado |
| `-target` / `-exclude` | emergência registrada; depois, plan completo vazio |
| `destroy` | gated como apply; em prd, ADR ou aprovação nomeada |
| `-replace=addr` | recria um recurso de propósito (substitui o antigo `taint`); revise no plan |
| `state rm/mv/push`, `force-unlock` | recuperação, com registro |
| `-refresh=false` | esconde drift; só para diagnóstico |
| `TF_LOG=trace` | despeja credencial no log; nunca em CI compartilhado |

## 8. Efeito externo

Recurso que **dispara** efeito no mundo (e-mail, webhook, DNS de envio, cobrança) não é aplicado
com valor real fora de prd. DNS de teste em rota nula, egress SMTP bloqueado e demais camadas:
`schematize-infra → references/iac-efeitos-externos.md`. O `plan` de hml/dev que aponta para
domínio de e-mail real é achado de revisão.
