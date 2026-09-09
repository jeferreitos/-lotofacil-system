# Sistema Lotofácil — importação automática, ciclos, filtros e conferência

## Arquitetura

```
Caixa (API oficial)  ──►  Edge Function (Supabase, Deno)  ──►  Postgres (Supabase)
                                    ▲
                        GitHub Actions (cron, grátis)
                                    │
                     dispara a Edge Function 6x/semana

Postgres:
  concursos            → histórico oficial (import automático)
  categorias_numeros   → primos / fibonacci / moldura / centro / mágicos / múltiplos de 3 / pares / ímpares
  ciclos_fechados       + dezenas_atrasadas (view)   → motor de ciclos
  meus_jogos            → seus jogos/apostas
  conferencias  (auto)  → conferência automática via trigger
  export_jogos_texto    → formato pronto pra copiar/colar no site da Caixa
```

Tudo roda no free tier do Supabase + GitHub Actions. Sem custo.

## Passo a passo de setup

### 1. Rodar as migrations no Supabase
No painel do Supabase → SQL Editor, rode nesta ordem (ou via `supabase db push` se
usar a CLI):
1. `supabase/migrations/0001_init.sql`
2. `supabase/migrations/0002_ciclos.sql`
3. `supabase/migrations/0003_exportacao.sql`

### 2. Deploy da Edge Function
```bash
supabase functions deploy importar-concursos --no-verify-jwt
```
(`--no-verify-jwt` porque quem chama é a GitHub Action com a service role key, não
um usuário logado.)

### 3. Configurar os secrets no GitHub
No repositório → Settings → Secrets and variables → Actions, adicione:
- `SUPABASE_FUNCTIONS_URL` → ex: `https://SEU-PROJETO.supabase.co/functions/v1`
- `SUPABASE_SERVICE_ROLE_KEY` → em Supabase → Project Settings → API

### 4. Carga inicial do histórico
Dispare manualmente o workflow uma vez com `backfill = true`
(GitHub → Actions → "Atualizar Lotofácil" → Run workflow → backfill: true).
Isso importa **todos** os concursos que faltam, do 1 até o mais recente.
Como a API da Caixa é gratuita mas não tem SLA, a function busca em lotes de 10
com pequena pausa entre eles pra não sobrecarregar — a carga inicial de ~2400+
concursos deve levar poucos minutos.

Depois disso, o cron cuida sozinho: roda automaticamente após cada sorteio
(seg a sáb, ~21h15 Brasília) e só busca o concurso novo.

### 5. Conferência automática
Já está pronta: assim que um concurso novo entra na tabela `concursos`, um
trigger confere **todos** os jogos com `status in ('ativo','jogado')` contra
aquele concurso e grava em `conferencias`. Pra ver o painel:
```sql
select * from painel_conferencias;
```

### 6. Ciclos (dezenas "atrasadas")
```sql
select * from dezenas_atrasadas;       -- estado atual de cada categoria
select * from duracao_media_ciclos;    -- quanto tempo cada ciclo costuma levar
```
`recalcular_ciclos()` já é chamado automaticamente pela Edge Function a cada
importação — não precisa rodar na mão, mas pode rodar manualmente se quiser
forçar um refresh: `select recalcular_ciclos();`

## Como cadastrar um jogo
```sql
insert into meus_jogos (nome, dezenas)
values ('Jogo 1 - teste', array[1,2,3,4,6,7,9,11,12,15,16,18,20,22,25]);
```

## Exportar pra apostar no site da Caixa
```sql
select nome, dezenas_formatadas from export_jogos_texto;
```
Isso já devolve as dezenas no formato "01 02 03 04 06 ..." — pronto pra colar
dezena por dezena no volante do https://loteriasonline.caixa.gov.br.

### Sobre automatizar o preenchimento no site da Caixa
Dá pra ir além da exportação em texto: existem extensões de navegador (Chrome)
que preenchem automaticamente os bilhetes no site da Caixa a partir de uma
lista de jogos, mas **deixam a conferência e a finalização/pagamento da aposta
sempre por conta do usuário** — e é assim que esse tipo de ferramenta deve
funcionar, tanto por segurança (é dinheiro real) quanto porque o site pode
mudar a qualquer momento.

Proposta pra próxima etapa: um userscript (Tampermonkey) que lê os jogos ativos
direto do Supabase (via uma function pública só de leitura) e preenche os
campos do volante automaticamente, parando sempre **antes** da confirmação de
pagamento — você só clica "seguir para pagamento". Pra isso eu preciso inspecionar
o HTML real do formulário em loteriasonline.caixa.gov.br (os seletores mudam
com frequência), então o ideal é montar isso com você acompanhando ao vivo,
ou você me mandar o HTML da tela de aposta pra eu mapear os campos certos.

## Próximos passos sugeridos
1. Gerador de jogos com os filtros da planilha CRIVO (pares/ímpares, soma,
   repetidas do concurso anterior, primos, moldura, mágicos, fibonacci) direto
   em SQL/Edge Function, já cruzando com `dezenas_atrasadas`.
2. Frontend simples (pode ser só um dashboard Supabase + um site estático, ou
   algo em React) pra visualizar ciclos, cadastrar jogos e ver o painel de
   conferência sem precisar mexer em SQL.
3. Userscript de preenchimento automático no site da Caixa (ver acima).
