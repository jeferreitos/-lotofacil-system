-- ============================================================
-- LOTOFÁCIL SYSTEM · Migration 0006
--   1) Banco recusa dezenas fora de 1-25 ou repetidas
--   2) Conferência também quando o jogo é cadastrado depois do sorteio,
--      quando o jogo muda e quando um concurso é corrigido
--   3) Distribuição histórica (vw_distribuicao_metricas) atualiza sozinha
--   4) Ciclo das 25 dezenas
--   5) recalcular_ciclos roda como dono (pra funcionar com login + RLS)
-- Pode rodar mais de uma vez sem problema.
-- ============================================================

-- ------------------------------------------------------------
-- 1) Validação das dezenas
-- ------------------------------------------------------------
create or replace function dezenas_ok(arr int[])
returns boolean language sql immutable as $$
  select coalesce(bool_and(d between 1 and 25), false)
         and count(distinct d) = count(*)
  from unnest(arr) d
$$;

alter table concursos drop constraint if exists concursos_dezenas_ok;
alter table concursos add constraint concursos_dezenas_ok check (dezenas_ok(dezenas));

alter table meus_jogos drop constraint if exists meus_jogos_dezenas_ok;
alter table meus_jogos add constraint meus_jogos_dezenas_ok check (dezenas_ok(dezenas));

-- ------------------------------------------------------------
-- 2a) Jogo cadastrado ou alterado: confere contra o concurso alvo (se já
--     foi sorteado) e refaz as conferências que ele já tinha
-- ------------------------------------------------------------
create or replace function conferir_jogo_alterado()
returns trigger language plpgsql security definer set search_path to 'public' as $$
begin
  -- mudou o concurso alvo: a conferência do alvo antigo não vale mais
  if tg_op = 'UPDATE' and new.concurso_alvo is not null
     and new.concurso_alvo is distinct from old.concurso_alvo then
    delete from conferencias where jogo_id = new.id and concurso <> new.concurso_alvo;
  end if;

  if coalesce(new.status, 'ativo') in ('ativo', 'jogado')
     and new.concurso_alvo is not null
     and exists (select 1 from concursos where concurso = new.concurso_alvo) then
    perform conferir_jogo(new.id, new.concurso_alvo);
  end if;

  if tg_op = 'UPDATE' then
    perform conferir_jogo(new.id, c.concurso)
    from conferencias c
    where c.jogo_id = new.id;
  end if;

  return new;
end;
$$;

drop trigger if exists trg_conferir_jogo_alterado on meus_jogos;
create trigger trg_conferir_jogo_alterado
  after insert or update of dezenas, concurso_alvo, status on meus_jogos
  for each row execute function conferir_jogo_alterado();

-- ------------------------------------------------------------
-- 2b) Concurso corrigido (ex: lançado à mão com dezena errada): refaz as
--     conferências e o crivo dele e do concurso seguinte (repetidas)
-- ------------------------------------------------------------
create or replace function concurso_alterado()
returns trigger language plpgsql security definer set search_path to 'public' as $$
begin
  perform conferir_jogo(j.id, new.concurso)
  from meus_jogos j
  where (j.status in ('ativo', 'jogado')
         and (j.concurso_alvo is null or j.concurso_alvo = new.concurso))
     or exists (select 1 from conferencias c where c.jogo_id = j.id and c.concurso = new.concurso);

  perform calcular_crivo_filtros(new.concurso);
  perform calcular_crivo_filtros(seguinte.concurso)
  from (select min(concurso) as concurso from concursos where concurso > new.concurso) seguinte
  where seguinte.concurso is not null;

  return new;
end;
$$;

drop trigger if exists trg_concurso_alterado on concursos;
create trigger trg_concurso_alterado
  after update of dezenas on concursos
  for each row execute function concurso_alterado();

-- ------------------------------------------------------------
-- 3) Distribuição histórica: recalcula sempre que a tabela de concursos
--    muda (antes ninguém chamava o refresh e ela ficava parada)
-- ------------------------------------------------------------
create or replace function trg_refresh_distribuicao()
returns trigger language plpgsql security definer set search_path to 'public' as $$
begin
  refresh materialized view vw_distribuicao_metricas;
  return null;
end;
$$;

drop trigger if exists trg_refresh_distribuicao on concursos;
create trigger trg_refresh_distribuicao
  after insert or update or delete on concursos
  for each statement execute function trg_refresh_distribuicao();

refresh materialized view vw_distribuicao_metricas;

-- ------------------------------------------------------------
-- 4) Ciclo das 25 dezenas: fecha quando todas as 25 já saíram
-- ------------------------------------------------------------
insert into categorias_numeros (categoria, dezena)
select 'todas_25', d from generate_series(1, 25) d
on conflict do nothing;

-- ------------------------------------------------------------
-- 5) recalcular_ciclos roda como dono da função, pra conseguir regravar
--    ciclos_fechados mesmo quando chamada pela página (usuário logado)
-- ------------------------------------------------------------
alter function recalcular_ciclos() security definer set search_path to 'public';

select recalcular_ciclos();
