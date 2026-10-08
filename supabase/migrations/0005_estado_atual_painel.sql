-- ============================================================
-- LOTOFÁCIL SYSTEM · Migration 0005: objetos criados direto no painel
--
-- Retrato (08/10/2026) do que existe no banco e que o index.html usa, mas
-- que tinha sido criado pelo SQL Editor do Supabase e não estava no
-- repositório. NÃO precisa rodar no banco atual (já está tudo lá); serve
-- pra recriar o sistema do zero junto com as migrations 0001-0004.
-- Tudo é idempotente (if not exists / create or replace).
--
-- Ficaram de fora sobras antigas que a página não usa (ver README):
--   gerar_jogo, gerar_jogo_interno, gerar_jogos_v1_backup,
--   sortear_dezenas_ponderado, faixa_aceitavel(text), ciclo_hazard,
--   atualizar_ciclo_estado_hist, tabelas ciclo_estado_hist,
--   gerador_config e v_ultimo, views ciclo_duracao_dist,
--   ciclo_duracao_stats, crivo_distribuicao e dezena_peso_*.
-- ============================================================

-- ------------------------------------------------------------
-- 1) CRIVO: métricas por concurso (base das "faixas aceitáveis")
-- ------------------------------------------------------------
create table if not exists crivo_filtros (
  concurso        integer primary key references concursos(concurso) on delete cascade,
  qtd_primos      integer not null,
  qtd_fibonacci   integer not null,
  qtd_moldura     integer not null,
  qtd_centro      integer not null,
  qtd_magicos     integer not null,
  qtd_multiplos_3 integer not null,
  qtd_repetidas   integer,
  qtd_linha1      integer not null,
  qtd_linha2      integer not null,
  qtd_linha3      integer not null,
  qtd_linha4      integer not null,
  qtd_linha5      integer not null,
  atualizado_em   timestamptz not null default now()
);

create or replace function calcular_crivo_filtros(p_concurso integer)
returns void language plpgsql as $$
declare
  v_dezenas   int[];
  v_anterior  int[];
  v_primos int; v_fibo int; v_moldura int; v_centro int;
  v_magicos int; v_mult3 int; v_repetidas int;
  v_l1 int; v_l2 int; v_l3 int; v_l4 int; v_l5 int;
begin
  select dezenas into v_dezenas from concursos where concurso = p_concurso;
  if v_dezenas is null then
    return;
  end if;

  select dezenas into v_anterior
  from concursos
  where concurso < p_concurso
  order by concurso desc
  limit 1;

  select count(*) into v_primos  from categorias_numeros where categoria = 'primos'      and dezena = any(v_dezenas);
  select count(*) into v_fibo    from categorias_numeros where categoria = 'fibonacci'    and dezena = any(v_dezenas);
  select count(*) into v_moldura from categorias_numeros where categoria = 'moldura'      and dezena = any(v_dezenas);
  select count(*) into v_centro  from categorias_numeros where categoria = 'centro'       and dezena = any(v_dezenas);
  select count(*) into v_magicos from categorias_numeros where categoria = 'magicos'      and dezena = any(v_dezenas);
  select count(*) into v_mult3   from categorias_numeros where categoria = 'multiplos_3'  and dezena = any(v_dezenas);

  if v_anterior is not null then
    select count(*) into v_repetidas from unnest(v_dezenas) d where d = any(v_anterior);
  else
    v_repetidas := null;
  end if;

  select count(*) into v_l1 from unnest(v_dezenas) d where d between 1 and 5;
  select count(*) into v_l2 from unnest(v_dezenas) d where d between 6 and 10;
  select count(*) into v_l3 from unnest(v_dezenas) d where d between 11 and 15;
  select count(*) into v_l4 from unnest(v_dezenas) d where d between 16 and 20;
  select count(*) into v_l5 from unnest(v_dezenas) d where d between 21 and 25;

  insert into crivo_filtros (
    concurso, qtd_primos, qtd_fibonacci, qtd_moldura, qtd_centro,
    qtd_magicos, qtd_multiplos_3, qtd_repetidas,
    qtd_linha1, qtd_linha2, qtd_linha3, qtd_linha4, qtd_linha5, atualizado_em
  ) values (
    p_concurso, v_primos, v_fibo, v_moldura, v_centro,
    v_magicos, v_mult3, v_repetidas,
    v_l1, v_l2, v_l3, v_l4, v_l5, now()
  )
  on conflict (concurso) do update set
    qtd_primos = excluded.qtd_primos, qtd_fibonacci = excluded.qtd_fibonacci,
    qtd_moldura = excluded.qtd_moldura, qtd_centro = excluded.qtd_centro,
    qtd_magicos = excluded.qtd_magicos, qtd_multiplos_3 = excluded.qtd_multiplos_3,
    qtd_repetidas = excluded.qtd_repetidas,
    qtd_linha1 = excluded.qtd_linha1, qtd_linha2 = excluded.qtd_linha2,
    qtd_linha3 = excluded.qtd_linha3, qtd_linha4 = excluded.qtd_linha4,
    qtd_linha5 = excluded.qtd_linha5, atualizado_em = now();
end;
$$;

create or replace function trg_calcular_crivo_filtros()
returns trigger language plpgsql security definer set search_path to 'public' as $$
begin
  perform calcular_crivo_filtros(new.concurso);
  return new;
end;
$$;

drop trigger if exists after_insert_concursos_crivo on concursos;
create trigger after_insert_concursos_crivo
  after insert on concursos
  for each row execute function trg_calcular_crivo_filtros();

-- ------------------------------------------------------------
-- 2) Conferência automática: versão do banco roda como dono da função
--    (security definer), pra conseguir gravar em "conferencias"
-- ------------------------------------------------------------
create or replace function conferir_todos_jogos_novo_concurso()
returns trigger language plpgsql security definer set search_path to 'public' as $$
begin
  perform conferir_jogo(j.id, new.concurso)
  from meus_jogos j
  where j.status in ('ativo','jogado')
    and (j.concurso_alvo is null or j.concurso_alvo = new.concurso);
  return new;
end;
$$;

-- ------------------------------------------------------------
-- 3) Faixas aceitáveis (percentis 10-90) — usadas na tabela de Meus jogos
-- ------------------------------------------------------------
create or replace function faixa_aceitavel(p_tabela text, p_coluna text)
returns numeric[] language plpgsql as $$
declare
  v_min numeric;
  v_max numeric;
begin
  execute format(
    'select percentile_cont(0.10) within group (order by %I),
            percentile_cont(0.90) within group (order by %I)
     from %I where %I is not null',
    p_coluna, p_coluna, p_tabela, p_coluna
  ) into v_min, v_max;
  return array[v_min, v_max];
end;
$$;

create or replace view concursos_metricas_extra as
select concurso,
  (select count(*) from unnest(c.dezenas) d(d) where d.d between 1 and 5)   as linha1,
  (select count(*) from unnest(c.dezenas) d(d) where d.d between 6 and 10)  as linha2,
  (select count(*) from unnest(c.dezenas) d(d) where d.d between 11 and 15) as linha3,
  (select count(*) from unnest(c.dezenas) d(d) where d.d between 16 and 20) as linha4,
  (select count(*) from unnest(c.dezenas) d(d) where d.d between 21 and 25) as linha5
from concursos c;

create or replace view faixas_aceitaveis as
select 'soma'::text as metrica, (faixa_aceitavel('concursos', 'soma'))[1] as min, (faixa_aceitavel('concursos', 'soma'))[2] as max
union all
select 'pares', (faixa_aceitavel('concursos', 'qtd_pares'))[1], (faixa_aceitavel('concursos', 'qtd_pares'))[2]
union all
select 'primos', (faixa_aceitavel('crivo_filtros', 'qtd_primos'))[1], (faixa_aceitavel('crivo_filtros', 'qtd_primos'))[2]
union all
select 'moldura', (faixa_aceitavel('crivo_filtros', 'qtd_moldura'))[1], (faixa_aceitavel('crivo_filtros', 'qtd_moldura'))[2]
union all
select 'magicos', (faixa_aceitavel('crivo_filtros', 'qtd_magicos'))[1], (faixa_aceitavel('crivo_filtros', 'qtd_magicos'))[2]
union all
select 'fibonacci', (faixa_aceitavel('crivo_filtros', 'qtd_fibonacci'))[1], (faixa_aceitavel('crivo_filtros', 'qtd_fibonacci'))[2]
union all
select 'repetidas', (faixa_aceitavel('crivo_filtros', 'qtd_repetidas'))[1], (faixa_aceitavel('crivo_filtros', 'qtd_repetidas'))[2]
union all
select 'linha1', (faixa_aceitavel('concursos_metricas_extra', 'linha1'))[1], (faixa_aceitavel('concursos_metricas_extra', 'linha1'))[2]
union all
select 'linha2', (faixa_aceitavel('concursos_metricas_extra', 'linha2'))[1], (faixa_aceitavel('concursos_metricas_extra', 'linha2'))[2]
union all
select 'linha3', (faixa_aceitavel('concursos_metricas_extra', 'linha3'))[1], (faixa_aceitavel('concursos_metricas_extra', 'linha3'))[2]
union all
select 'linha4', (faixa_aceitavel('concursos_metricas_extra', 'linha4'))[1], (faixa_aceitavel('concursos_metricas_extra', 'linha4'))[2]
union all
select 'linha5', (faixa_aceitavel('concursos_metricas_extra', 'linha5'))[1], (faixa_aceitavel('concursos_metricas_extra', 'linha5'))[2];

-- ------------------------------------------------------------
-- 4) Métricas dos meus jogos (aba Meus jogos)
-- ------------------------------------------------------------
create or replace function metricas_para_dezenas(p_dezenas integer[], p_anterior integer[] default null)
returns table (soma integer, pares integer, primos integer, moldura integer, magicos integer,
               fibonacci integer, repetidas integer, linha1 integer, linha2 integer,
               linha3 integer, linha4 integer, linha5 integer)
language sql stable as $$
  select
    (select sum(d)::int from unnest(p_dezenas) d),
    (select count(*)::int from unnest(p_dezenas) d where d % 2 = 0),
    (select count(*)::int from categorias_numeros where categoria = 'primos' and dezena = any(p_dezenas)),
    (select count(*)::int from categorias_numeros where categoria = 'moldura' and dezena = any(p_dezenas)),
    (select count(*)::int from categorias_numeros where categoria = 'magicos' and dezena = any(p_dezenas)),
    (select count(*)::int from categorias_numeros where categoria = 'fibonacci' and dezena = any(p_dezenas)),
    (select count(*)::int from unnest(p_dezenas) d where p_anterior is not null and d = any(p_anterior)),
    (select count(*)::int from unnest(p_dezenas) d where d between 1 and 5),
    (select count(*)::int from unnest(p_dezenas) d where d between 6 and 10),
    (select count(*)::int from unnest(p_dezenas) d where d between 11 and 15),
    (select count(*)::int from unnest(p_dezenas) d where d between 16 and 20),
    (select count(*)::int from unnest(p_dezenas) d where d between 21 and 25);
$$;

create or replace view meus_jogos_metricas as
select mj.id, mj.nome, mj.status, mj.dezenas,
       m.soma, m.pares, m.primos, m.moldura, m.magicos, m.fibonacci, m.repetidas,
       m.linha1, m.linha2, m.linha3, m.linha4, m.linha5,
       mj.concurso_alvo, mj.origem, mj.criado_em
from meus_jogos mj
cross join lateral metricas_para_dezenas(
  mj.dezenas,
  (select concursos.dezenas from concursos order by concursos.concurso desc limit 1)
) m;

-- ------------------------------------------------------------
-- 5) Distribuição histórica (grade de Meus jogos + nota IFJ do gerador)
-- ------------------------------------------------------------
create or replace view vw_concursos_metricas as
with base as (
  select c.concurso, c.dezenas,
         lag(c.dezenas) over (order by c.concurso) as dezenas_anterior
  from concursos c
)
select concurso,
  (select count(*) from unnest(b.dezenas) d(d) where d.d = any(b.dezenas_anterior)) as repetidas,
  (select count(*) from unnest(b.dezenas) d(d) where d.d in (select dezena from categorias_numeros where categoria = 'primos'))    as primos,
  (select count(*) from unnest(b.dezenas) d(d) where d.d in (select dezena from categorias_numeros where categoria = 'moldura'))   as moldura,
  (select count(*) from unnest(b.dezenas) d(d) where d.d in (select dezena from categorias_numeros where categoria = 'magicos'))   as magicos,
  (select count(*) from unnest(b.dezenas) d(d) where d.d in (select dezena from categorias_numeros where categoria = 'fibonacci')) as fibonacci,
  (select count(*) from unnest(b.dezenas) d(d) where d.d between 1 and 5)   as linha1,
  (select count(*) from unnest(b.dezenas) d(d) where d.d between 6 and 10)  as linha2,
  (select count(*) from unnest(b.dezenas) d(d) where d.d between 11 and 15) as linha3,
  (select count(*) from unnest(b.dezenas) d(d) where d.d between 16 and 20) as linha4,
  (select count(*) from unnest(b.dezenas) d(d) where d.d between 21 and 25) as linha5,
  (select count(*) from unnest(b.dezenas) d(d) where d.d % 2 = 0) as pares,
  (select count(*) from unnest(b.dezenas) d(d) where d.d % 2 = 1) as impares,
  (select sum(d.d) from unnest(b.dezenas) d(d)) as soma
from base b
where dezenas_anterior is not null;

create materialized view if not exists vw_distribuicao_metricas as
          select 'primos'::text as metrica, primos as valor, count(*) as quantidade from vw_concursos_metricas group by primos
union all select 'moldura',   moldura,   count(*) from vw_concursos_metricas group by moldura
union all select 'magicos',   magicos,   count(*) from vw_concursos_metricas group by magicos
union all select 'fibonacci', fibonacci, count(*) from vw_concursos_metricas group by fibonacci
union all select 'linha1',    linha1,    count(*) from vw_concursos_metricas group by linha1
union all select 'linha2',    linha2,    count(*) from vw_concursos_metricas group by linha2
union all select 'linha3',    linha3,    count(*) from vw_concursos_metricas group by linha3
union all select 'linha4',    linha4,    count(*) from vw_concursos_metricas group by linha4
union all select 'linha5',    linha5,    count(*) from vw_concursos_metricas group by linha5
union all select 'repetidas', repetidas, count(*) from vw_concursos_metricas group by repetidas
union all select 'pares',     pares,     count(*) from vw_concursos_metricas group by pares
union all select 'impares',   impares,   count(*) from vw_concursos_metricas group by impares
union all select 'soma', (soma / 10) * 10, count(*) from vw_concursos_metricas group by (soma / 10) * 10;

create unique index if not exists vw_distribuicao_metricas_idx
  on vw_distribuicao_metricas (metrica, valor);

create or replace function refresh_vw_distribuicao_metricas()
returns void language plpgsql security definer as $$
begin
  refresh materialized view concurrently vw_distribuicao_metricas;
end;
$$;

-- ------------------------------------------------------------
-- 6) Atraso por dezena (aba Análise)
-- ------------------------------------------------------------
create or replace view atraso_dezenas_individual as
select dz.dezena,
       (select max(concurso) from concursos) - max(c.concurso) as atraso,
       max(c.concurso) as ultimo_concurso
from generate_series(1, 25) dz(dezena)
join concursos c on dz.dezena = any(c.dezenas)
group by dz.dezena
order by dz.dezena;

-- ------------------------------------------------------------
-- 7) Gerador IFJ (aba Gerar jogos)
-- ------------------------------------------------------------
create or replace function gerar_jogos(p_qtd integer default 5)
returns table (dezenas integer[], categoria text, ifj_total integer,
               valor_soma integer, pontos_soma integer,
               valor_pares integer, pontos_pares integer,
               valor_repetidas integer, pontos_repetidas integer,
               valor_primos integer, pontos_primos integer,
               valor_moldura integer, pontos_moldura integer,
               valor_fibonacci integer, pontos_fibonacci integer,
               valor_magicos integer, pontos_magicos integer)
language plpgsql as $function$
#variable_conflict use_column
declare
  max_freq_soma      numeric;
  max_freq_pares     numeric;
  max_freq_repetidas numeric;
  max_freq_primos    numeric;
  max_freq_moldura   numeric;
  max_freq_fibonacci numeric;
  max_freq_magicos   numeric;
  ultimo_concurso    int[];
  arr_primos         int[];
  arr_moldura        int[];
  arr_fibonacci      int[];
  arr_magicos        int[];

  aceitos            jsonb := '[]'::jsonb;
  rec                record;

  q_super int; q_prem int; q_bom int; q_cob int;
  diff    int;

  v_cap              int;
  cont_repetidas     int[] := array_fill(0, array[16]);
  cont_primos        int[] := array_fill(0, array[16]);
  cont_moldura       int[] := array_fill(0, array[16]);
  cont_magicos       int[] := array_fill(0, array[16]);
  cont_fibonacci     int[] := array_fill(0, array[16]);
  cont_pares         int[] := array_fill(0, array[16]);
  v_idx_rep int; v_idx_pri int; v_idx_mol int; v_idx_mag int; v_idx_fib int; v_idx_par int;

  -- Busca por categoria: cada uma tem sua própria janela de nota e roda
  -- isolada, com pool crescente, até fechar a cota dela ou esgotar as
  -- tentativas — assim uma categoria "fácil" (Super Premium) não consome
  -- o orçamento de tentativas que uma difícil (Cobertura) precisa.
  tier_codigos   text[] := array['S','P','B','C'];
  tier_codigo    text;
  tier_min       int;
  tier_max       int;
  tier_quota     int;
  tier_count     int;
  pool_size_tier int;
  tentativa_tier int;
  max_tentativas_tier int := 6;
  i int;
begin
  if p_qtd is null or p_qtd < 1 then
    p_qtd := 5;
  end if;

  v_cap := greatest(2, ceil(p_qtd / 4.0)::int);

  q_super := round(p_qtd * 0.3)::int;
  q_prem  := round(p_qtd * 0.3)::int;
  q_bom   := round(p_qtd * 0.3)::int;
  q_cob   := round(p_qtd * 0.1)::int;

  diff := p_qtd - (q_super + q_prem + q_bom + q_cob);

  while diff > 0 loop
    if q_super <= q_prem and q_super <= q_bom then
      q_super := q_super + 1;
    elsif q_prem <= q_bom then
      q_prem := q_prem + 1;
    else
      q_bom := q_bom + 1;
    end if;
    diff := diff - 1;
  end loop;

  while diff < 0 loop
    if q_super >= q_prem and q_super >= q_bom and q_super > 0 then
      q_super := q_super - 1;
    elsif q_prem >= q_bom and q_prem > 0 then
      q_prem := q_prem - 1;
    elsif q_bom > 0 then
      q_bom := q_bom - 1;
    elsif q_cob > 0 then
      q_cob := q_cob - 1;
    else
      exit;
    end if;
    diff := diff + 1;
  end loop;

  if q_cob = 0 and p_qtd >= 4 then
    q_cob := 1;
    if q_super >= q_prem and q_super >= q_bom and q_super > 0 then
      q_super := q_super - 1;
    elsif q_prem >= q_bom and q_prem > 0 then
      q_prem := q_prem - 1;
    elsif q_bom > 0 then
      q_bom := q_bom - 1;
    end if;
  end if;

  max_freq_soma      := (select max(v.quantidade) from public.vw_distribuicao_metricas v where v.metrica = 'soma');
  max_freq_pares     := (select max(v.quantidade) from public.vw_distribuicao_metricas v where v.metrica = 'pares');
  max_freq_repetidas := (select max(v.quantidade) from public.vw_distribuicao_metricas v where v.metrica = 'repetidas');
  max_freq_primos    := (select max(v.quantidade) from public.vw_distribuicao_metricas v where v.metrica = 'primos');
  max_freq_moldura   := (select max(v.quantidade) from public.vw_distribuicao_metricas v where v.metrica = 'moldura');
  max_freq_fibonacci := (select max(v.quantidade) from public.vw_distribuicao_metricas v where v.metrica = 'fibonacci');
  max_freq_magicos   := (select max(v.quantidade) from public.vw_distribuicao_metricas v where v.metrica = 'magicos');

  if coalesce(max_freq_soma,0)=0 or coalesce(max_freq_pares,0)=0 or coalesce(max_freq_repetidas,0)=0
     or coalesce(max_freq_primos,0)=0 or coalesce(max_freq_moldura,0)=0
     or coalesce(max_freq_fibonacci,0)=0 or coalesce(max_freq_magicos,0)=0 then
    raise exception 'vw_distribuicao_metricas precisa ter dados para soma, pares, repetidas, primos, moldura, fibonacci e magicos';
  end if;

  ultimo_concurso := (select c.dezenas from public.concursos c order by c.concurso desc limit 1);
  if ultimo_concurso is null then
    raise exception 'Nao ha concursos cadastrados para calcular repetidas';
  end if;

  arr_primos    := (select array_agg(cn.dezena) from public.categorias_numeros cn where cn.categoria = 'primos');
  arr_moldura   := (select array_agg(cn.dezena) from public.categorias_numeros cn where cn.categoria = 'moldura');
  arr_fibonacci := (select array_agg(cn.dezena) from public.categorias_numeros cn where cn.categoria = 'fibonacci');
  arr_magicos   := (select array_agg(cn.dezena) from public.categorias_numeros cn where cn.categoria = 'magicos');

  for i in 1..4 loop
    tier_codigo := tier_codigos[i];

    if tier_codigo = 'S' then tier_min := 98;  tier_max := 100; tier_quota := q_super;
    elsif tier_codigo = 'P' then tier_min := 94;  tier_max := 97;  tier_quota := q_prem;
    elsif tier_codigo = 'B' then tier_min := 85;  tier_max := 89;  tier_quota := q_bom;
    else                          tier_min := 80;  tier_max := 84;  tier_quota := q_cob;
    end if;

    -- pula pro próximo tier se este pediu 0 jogos
    continue when tier_quota <= 0;

    tier_count := 0;
    pool_size_tier := 3000;
    tentativa_tier := 0;

    while tier_count < tier_quota and tentativa_tier < max_tentativas_tier loop
      tentativa_tier := tentativa_tier + 1;

      for rec in
        with pool as (
          select g.candidato, t.n,
                 row_number() over (partition by g.candidato order by random()) as ord
          from generate_series(1, pool_size_tier) as g(candidato)
          cross join generate_series(1,25) as t(n)
        ),
        escolhidos as (
          select candidato, n
          from pool
          where ord <= 15
        ),
        base as (
          select
            e.candidato,
            array_agg(e.n order by e.n) as dezenas,
            sum(e.n)::int as valor_soma,
            count(*) filter (where e.n % 2 = 0)::int as valor_pares,
            count(*) filter (where e.n = any(ultimo_concurso))::int as valor_repetidas,
            count(*) filter (where e.n = any(arr_primos))::int as valor_primos,
            count(*) filter (where e.n = any(arr_moldura))::int as valor_moldura,
            count(*) filter (where e.n = any(arr_fibonacci))::int as valor_fibonacci,
            count(*) filter (where e.n = any(arr_magicos))::int as valor_magicos
          from escolhidos e
          group by e.candidato
        ),
        pontuado as (
          select
            b.dezenas,
            b.valor_soma, b.valor_pares, b.valor_repetidas, b.valor_primos,
            b.valor_moldura, b.valor_fibonacci, b.valor_magicos,
            round(coalesce(fs.quantidade,0)  / max_freq_soma      * 20)::int as pontos_soma,
            round(coalesce(fp.quantidade,0)  / max_freq_pares     * 20)::int as pontos_pares,
            round(coalesce(fr.quantidade,0)  / max_freq_repetidas * 20)::int as pontos_repetidas,
            round(coalesce(fpr.quantidade,0) / max_freq_primos    * 15)::int as pontos_primos,
            round(coalesce(fm.quantidade,0)  / max_freq_moldura   * 10)::int as pontos_moldura,
            round(coalesce(ff.quantidade,0)  / max_freq_fibonacci * 10)::int as pontos_fibonacci,
            round(coalesce(fma.quantidade,0) / max_freq_magicos   * 5)::int  as pontos_magicos
          from base b
          left join public.vw_distribuicao_metricas fs  on fs.metrica='soma'      and fs.valor=(b.valor_soma/10)*10
          left join public.vw_distribuicao_metricas fp  on fp.metrica='pares'     and fp.valor=b.valor_pares
          left join public.vw_distribuicao_metricas fr  on fr.metrica='repetidas' and fr.valor=b.valor_repetidas
          left join public.vw_distribuicao_metricas fpr on fpr.metrica='primos'   and fpr.valor=b.valor_primos
          left join public.vw_distribuicao_metricas fm  on fm.metrica='moldura'   and fm.valor=b.valor_moldura
          left join public.vw_distribuicao_metricas ff  on ff.metrica='fibonacci' and ff.valor=b.valor_fibonacci
          left join public.vw_distribuicao_metricas fma on fma.metrica='magicos'  and fma.valor=b.valor_magicos
        )
        select p.*,
               (p.pontos_soma+p.pontos_pares+p.pontos_repetidas+p.pontos_primos
                +p.pontos_moldura+p.pontos_fibonacci+p.pontos_magicos)::int as ifj_total
        from pontuado p
        where (p.pontos_soma+p.pontos_pares+p.pontos_repetidas+p.pontos_primos
               +p.pontos_moldura+p.pontos_fibonacci+p.pontos_magicos) between tier_min and tier_max
        order by random()
      loop
        exit when tier_count >= tier_quota;

        v_idx_rep := rec.valor_repetidas + 1;
        v_idx_pri := rec.valor_primos + 1;
        v_idx_mol := rec.valor_moldura + 1;
        v_idx_mag := rec.valor_magicos + 1;
        v_idx_fib := rec.valor_fibonacci + 1;
        v_idx_par := rec.valor_pares + 1;

        -- Teto de variedade por critério: não vale pra Cobertura, que já
        -- é naturalmente rara e precisa de toda ajuda pra fechar a cota.
        continue when tier_codigo <> 'C' and (
                   cont_repetidas[v_idx_rep] >= v_cap
                   or cont_primos[v_idx_pri]     >= v_cap
                   or cont_moldura[v_idx_mol]    >= v_cap
                   or cont_magicos[v_idx_mag]    >= v_cap
                   or cont_fibonacci[v_idx_fib]  >= v_cap
                   or cont_pares[v_idx_par]      >= v_cap
                 );

        if not exists (
          select 1
          from jsonb_array_elements(aceitos) e
          where (
            select count(*)
            from jsonb_array_elements_text(e -> 'dezenas') d
            where d.value::int = any(rec.dezenas)
          ) >= 13
        ) then
          aceitos := aceitos || jsonb_build_array(to_jsonb(rec) || jsonb_build_object('categoria', tier_codigo));
          cont_repetidas[v_idx_rep] := cont_repetidas[v_idx_rep] + 1;
          cont_primos[v_idx_pri]    := cont_primos[v_idx_pri] + 1;
          cont_moldura[v_idx_mol]   := cont_moldura[v_idx_mol] + 1;
          cont_magicos[v_idx_mag]   := cont_magicos[v_idx_mag] + 1;
          cont_fibonacci[v_idx_fib] := cont_fibonacci[v_idx_fib] + 1;
          cont_pares[v_idx_par]     := cont_pares[v_idx_par] + 1;
          tier_count := tier_count + 1;
        end if;
      end loop;

      pool_size_tier := pool_size_tier * 2;
    end loop;
  end loop;

  return query
  select
    x.dezenas,
    case x.categoria
      when 'S' then 'SUPER PREMIUM'
      when 'P' then 'PREMIUM'
      when 'B' then 'BOM'
      when 'C' then 'COBERTURA'
    end,
    x.ifj_total,
    x.valor_soma, x.pontos_soma,
    x.valor_pares, x.pontos_pares,
    x.valor_repetidas, x.pontos_repetidas,
    x.valor_primos, x.pontos_primos,
    x.valor_moldura, x.pontos_moldura,
    x.valor_fibonacci, x.pontos_fibonacci,
    x.valor_magicos, x.pontos_magicos
  from jsonb_to_recordset(aceitos) as x(
    dezenas int[], categoria text, ifj_total int,
    valor_soma int, pontos_soma int,
    valor_pares int, pontos_pares int,
    valor_repetidas int, pontos_repetidas int,
    valor_primos int, pontos_primos int,
    valor_moldura int, pontos_moldura int,
    valor_fibonacci int, pontos_fibonacci int,
    valor_magicos int, pontos_magicos int
  )
  order by x.ifj_total desc;
end;
$function$;

-- ------------------------------------------------------------
-- 8) RLS ligado nas tabelas (as regras de acesso ficam na 0007)
-- ------------------------------------------------------------
alter table categorias_numeros enable row level security;
alter table ciclos_fechados    enable row level security;
alter table concursos          enable row level security;
alter table conferencias       enable row level security;
alter table crivo_filtros      enable row level security;
alter table meus_jogos         enable row level security;
