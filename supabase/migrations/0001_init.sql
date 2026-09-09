-- ============================================================
-- LOTOFÁCIL SYSTEM · Migration 0001: schema base
-- ============================================================

-- ------------------------------------------------------------
-- Funções auxiliares IMMUTABLE (colunas "generated" do Postgres não aceitam
-- subquery direto na expressão, então isolamos a lógica em funções)
-- ------------------------------------------------------------
create or replace function array_sum(arr int[]) returns int
  language sql immutable as $$
    select sum(x) from unnest(arr) x
  $$;

create or replace function array_count_pares(arr int[]) returns int
  language sql immutable as $$
    select count(*) from unnest(arr) x where x % 2 = 0
  $$;

create or replace function array_count_impares(arr int[]) returns int
  language sql immutable as $$
    select count(*) from unnest(arr) x where x % 2 <> 0
  $$;

-- ------------------------------------------------------------
-- 1) CONCURSOS (histórico oficial da Caixa)
-- ------------------------------------------------------------
create table if not exists concursos (
  concurso        integer primary key,
  data_sorteio    date not null,
  dezenas         integer[] not null,           -- as 15 dezenas sorteadas, ordenadas
  acumulou        boolean,
  valor_acumulado numeric(14,2),
  criado_em       timestamptz not null default now(),
  constraint dezenas_len check (array_length(dezenas, 1) = 15)
);

create index if not exists idx_concursos_data on concursos (data_sorteio desc);

-- Colunas calculadas (equivalente às fórmulas da planilha ANALISE)
alter table concursos add column if not exists soma int
  generated always as (array_sum(dezenas)) stored;

alter table concursos add column if not exists qtd_pares int
  generated always as (array_count_pares(dezenas)) stored;

alter table concursos add column if not exists qtd_impares int
  generated always as (array_count_impares(dezenas)) stored;

-- ------------------------------------------------------------
-- 2) CATEGORIAS DE NÚMEROS (conjuntos fixos usados nos filtros e ciclos)
--    primos / fibonacci / multiplos_3 / magicos / moldura / centro / pares / impares
-- ------------------------------------------------------------
create table if not exists categorias_numeros (
  categoria text not null,
  dezena    int  not null,
  primary key (categoria, dezena)
);

insert into categorias_numeros (categoria, dezena) values
  ('primos',2),('primos',3),('primos',5),('primos',7),('primos',11),('primos',13),('primos',17),('primos',19),('primos',23),
  ('fibonacci',1),('fibonacci',2),('fibonacci',3),('fibonacci',5),('fibonacci',8),('fibonacci',13),('fibonacci',21),
  ('multiplos_3',3),('multiplos_3',6),('multiplos_3',9),('multiplos_3',12),('multiplos_3',15),('multiplos_3',18),('multiplos_3',21),('multiplos_3',24),
  ('magicos',5),('magicos',6),('magicos',7),('magicos',12),('magicos',13),('magicos',14),('magicos',19),('magicos',20),('magicos',21),
  ('moldura',1),('moldura',2),('moldura',3),('moldura',4),('moldura',5),('moldura',6),('moldura',10),('moldura',11),
  ('moldura',15),('moldura',16),('moldura',20),('moldura',21),('moldura',22),('moldura',23),('moldura',24),('moldura',25),
  ('centro',7),('centro',8),('centro',9),('centro',12),('centro',13),('centro',14),('centro',17),('centro',18),('centro',19),
  ('pares',2),('pares',4),('pares',6),('pares',8),('pares',10),('pares',12),('pares',14),('pares',16),('pares',18),('pares',20),('pares',22),('pares',24),
  ('impares',1),('impares',3),('impares',5),('impares',7),('impares',9),('impares',11),('impares',13),('impares',15),('impares',17),('impares',19),('impares',21),('impares',23),('impares',25)
on conflict do nothing;

-- ------------------------------------------------------------
-- 3) MEUS JOGOS (apostas que você monta / gera)
-- ------------------------------------------------------------
create table if not exists meus_jogos (
  id              uuid primary key default gen_random_uuid(),
  nome            text,                          -- rótulo livre, ex: "Filtro soma 190-200"
  dezenas         integer[] not null,
  concurso_alvo   integer references concursos(concurso), -- null = "para o próximo concurso"
  origem          text default 'manual',         -- manual | gerado | importado
  status          text default 'ativo',          -- ativo | jogado | arquivado
  criado_em       timestamptz not null default now(),
  constraint dezenas_validas check (array_length(dezenas,1) between 15 and 20)
);

-- ------------------------------------------------------------
-- 4) CONFERÊNCIAS (resultado de cada jogo contra cada concurso)
-- ------------------------------------------------------------
create table if not exists conferencias (
  id          uuid primary key default gen_random_uuid(),
  jogo_id     uuid not null references meus_jogos(id) on delete cascade,
  concurso    integer not null references concursos(concurso) on delete cascade,
  acertos     int not null,
  premiado    boolean not null default false,
  faixa       text,                              -- "15 pontos", "14 pontos" etc
  criado_em   timestamptz not null default now(),
  unique (jogo_id, concurso)
);

-- Faixas de premiação da Lotofácil (11 a 15 acertos pagam)
create or replace function faixa_premio(p_acertos int)
returns text language sql immutable as $$
  select case
    when p_acertos = 15 then '15 pontos'
    when p_acertos = 14 then '14 pontos'
    when p_acertos = 13 then '13 pontos'
    when p_acertos = 12 then '12 pontos'
    when p_acertos = 11 then '11 pontos'
    else null
  end
$$;

-- Concfere UM jogo contra UM concurso
create or replace function conferir_jogo(p_jogo_id uuid, p_concurso int)
returns void language plpgsql as $$
declare
  v_dezenas_jogo int[];
  v_dezenas_concurso int[];
  v_acertos int;
begin
  select dezenas into v_dezenas_jogo from meus_jogos where id = p_jogo_id;
  select dezenas into v_dezenas_concurso from concursos where concurso = p_concurso;

  select count(*) into v_acertos
  from unnest(v_dezenas_jogo) d
  where d = any(v_dezenas_concurso);

  insert into conferencias (jogo_id, concurso, acertos, premiado, faixa)
  values (p_jogo_id, p_concurso, v_acertos, v_acertos >= 11, faixa_premio(v_acertos))
  on conflict (jogo_id, concurso) do update
    set acertos = excluded.acertos,
        premiado = excluded.premiado,
        faixa = excluded.faixa;
end;
$$;

-- Conferência automática: sempre que um concurso novo entra, confere TODOS os jogos ativos
create or replace function conferir_todos_jogos_novo_concurso()
returns trigger language plpgsql as $$
begin
  perform conferir_jogo(j.id, new.concurso)
  from meus_jogos j
  where j.status in ('ativo','jogado')
    and (j.concurso_alvo is null or j.concurso_alvo = new.concurso);
  return new;
end;
$$;

drop trigger if exists trg_conferir_novo_concurso on concursos;
create trigger trg_conferir_novo_concurso
  after insert on concursos
  for each row execute function conferir_todos_jogos_novo_concurso();

-- View de painel: última conferência de cada jogo
create or replace view painel_conferencias as
select
  j.id as jogo_id,
  j.nome,
  j.dezenas,
  c.concurso,
  c.acertos,
  c.premiado,
  c.faixa,
  co.data_sorteio
from meus_jogos j
join conferencias c on c.jogo_id = j.id
join concursos co on co.concurso = c.concurso
order by co.concurso desc, c.acertos desc;
