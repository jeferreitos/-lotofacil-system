# Sistema Lotofácil — importação automática, ciclos, gerador e conferência

Painel publicado pelo GitHub Pages a partir da branch `main` (`index.html`),
com banco no Supabase. **Tudo que entra na `main` vai direto pro ar.**

## Arquitetura

```
Caixa (API oficial)  ──►  Edge Function (Supabase, Deno)  ──►  Postgres (Supabase)
                                    ▲                               ▲
                        GitHub Actions (cron, grátis)        index.html (login)
                                    │
                     dispara a Edge Function 6x/semana

Postgres:
  concursos              → histórico oficial (import automático ou lançamento manual)
  categorias_numeros     → primos / fibonacci / moldura / centro / mágicos / múltiplos de 3 /
                           pares / ímpares / todas_25 (ciclo das 25 dezenas)
  ciclos_fechados        + dezenas_atrasadas (view)   → motor de ciclos
  crivo_filtros          → métricas de cada concurso (base das faixas aceitáveis)
  vw_distribuicao_metricas (materialized view) → distribuição histórica usada pelo
                           gerador IFJ e pela grade de Meus jogos
  gerar_jogos()          → gerador IFJ (aba Gerar jogos)
  meus_jogos             → seus jogos/apostas
  conferencias  (auto)   → conferência automática via trigger
  usuarios_autorizados   → quem pode acessar o painel (login)
```

## Migrations

Rode nesta ordem no SQL Editor do Supabase (ou `supabase db push`):

| Arquivo | O que faz |
| --- | --- |
| `0001_init.sql` | tabelas base, conferência automática |
| `0002_ciclos.sql` | motor de ciclos |
| `0003_exportacao.sql` | views de exportação |
| `0004_remove_fk_concurso_alvo.sql` | permite jogo para concurso ainda não sorteado |
| `0005_estado_atual_painel.sql` | gerador IFJ, métricas, crivo e views criados direto no painel (retrato de 08/10/2026) |
| `0006_conferencia_validacao_ciclo25.sql` | validação de dezenas, conferência de jogo cadastrado depois do sorteio, distribuição histórica sempre atualizada, ciclo das 25 dezenas |
| `0007_login_rls.sql` | acesso só com login de usuário autorizado |
| `0008_limpeza_sobras.sql` | remove sobras de versões antigas do gerador |

## Acesso (login)

1. Supabase → Authentication → Users → **Add user** (e-mail e senha, marque *Auto Confirm*).
2. Supabase → Authentication → Sign In / Providers → Email: **desligue "Allow new users to sign up"**.
3. Libere o usuário no SQL Editor:
   ```sql
   insert into usuarios_autorizados (user_id)
   select id from auth.users where email = 'SEU_EMAIL_AQUI'
   on conflict do nothing;
   ```

Mesmo que alguém consiga criar conta, sem estar em `usuarios_autorizados` não lê nem altera nada.

## Importação automática

Uma Edge Function só, código em `supabase/functions/swift-action/index.ts`
(baixado do Supabase em 08/10/2026). No painel do Supabase ela aparece com o
nome **importar-concursos**, mas o endereço dela é `/functions/v1/swift-action`.
Ela atende os dois endereços:
- `/importar-concursos` — chamado pelo GitHub Actions (cron).
- `/swift-action` — chamado pelo botão "Atualizar resultados" do painel.

Busca os resultados na API oficial da Caixa e, se ela falhar, no mirror
comunitário `loteriascaixa-api.herokuapp.com`. Numa execução normal importa
o que falta nos últimos 30 concursos e depois do último salvo; com
`{"backfill": true}` no corpo preenche todos os buracos do histórico. Concurso
já salvo não é baixado de novo. Grava com a chave de serviço (não depende do
login), recalcula os ciclos e responde quantos concursos salvou de fato.

```bash
supabase functions deploy swift-action --no-verify-jwt
```

Secrets do repositório (Settings → Secrets and variables → Actions):
- `SUPABASE_FUNCTIONS_URL` → ex: `https://SEU-PROJETO.supabase.co/functions/v1`
- `SUPABASE_SERVICE_ROLE_KEY` → em Supabase → Project Settings → API

Carga inicial: GitHub → Actions → "Atualizar Lotofácil" → Run workflow → `backfill: true`.
Depois disso o cron roda sozinho após cada sorteio (seg a sáb, ~21h15 Brasília). Se a
function der erro, o job fica vermelho no GitHub.

## Automático no banco

- Concurso novo → confere todos os jogos ativos, calcula o crivo e atualiza a distribuição histórica.
- Concurso corrigido → refaz as conferências e o crivo dele e do seguinte.
- Jogo cadastrado para um concurso que já saiu → conferido na hora.
- Dezenas fora de 1–25 ou repetidas são recusadas.

## Sobras antigas

A migration `0008_limpeza_sobras.sql` remove funções, tabelas e views de versões
antigas do gerador que o painel não usa mais.
