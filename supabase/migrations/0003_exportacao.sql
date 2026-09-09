-- ============================================================
-- LOTOFÁCIL SYSTEM · Migration 0003: exportação para apostar
-- ============================================================

-- Formata cada jogo ativo como texto pronto pra copiar e colar
-- (dezenas separadas por espaço, com 2 dígitos, como o volante espera)
create or replace view export_jogos_texto as
select
  j.id,
  j.nome,
  (
    select string_agg(lpad(d::text, 2, '0'), ' ' order by d)
    from unnest(j.dezenas) d
  ) as dezenas_formatadas,
  array_length(j.dezenas, 1) as qtd_dezenas,
  j.concurso_alvo,
  j.status
from meus_jogos j
where j.status = 'ativo'
order by j.criado_em desc;

-- Formato "CSV de um jogo por linha", útil pra importar em outras ferramentas
-- ou pra colar em lote em quem aceita lista de jogos
create or replace view export_jogos_csv as
select
  j.id,
  j.nome,
  (
    select string_agg(d::text, ',' order by d)
    from unnest(j.dezenas) d
  ) as dezenas_csv
from meus_jogos j
where j.status = 'ativo'
order by j.criado_em desc;
