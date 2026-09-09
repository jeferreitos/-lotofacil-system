-- ============================================================
-- LOTOFÁCIL SYSTEM · Migration 0002: motor de ciclos
-- Replica a lógica da planilha "Ciclo da Lotofácil":
-- para cada categoria (primos, fibonacci, moldura, centro,
-- magicos, multiplos_3, pares, impares), acompanha quais
-- dezenas ainda faltam sair para "fechar o ciclo" e quantos
-- concursos o ciclo atual já leva aberto.
-- ============================================================

-- Histórico de ciclos já fechados (permite ver quanto tempo cada ciclo levou)
create table if not exists ciclos_fechados (
  id                  bigserial primary key,
  categoria           text not null,
  numero_ciclo        int  not null,
  concurso_abertura   int  not null references concursos(concurso),
  concurso_fechamento int  not null references concursos(concurso),
  qtd_concursos       int  not null,
  unique (categoria, numero_ciclo)
);

-- Recalcula do zero o histórico de ciclos fechados para TODAS as categorias.
-- Chamar sempre depois de importar concurso(s) novo(s) (é rápido: histórico da
-- Lotofácil tem só ~2 mil linhas).
create or replace function recalcular_ciclos()
returns void language plpgsql as $$
declare
  v_categoria      text;
  v_conjunto_total int[];
  v_faltando       int[];
  v_concurso       record;
  v_abertura       int;
  v_numero_ciclo   int;
begin
  truncate table ciclos_fechados;

  for v_categoria in select distinct categoria from categorias_numeros loop

    select array_agg(dezena order by dezena) into v_conjunto_total
    from categorias_numeros where categoria = v_categoria;

    v_faltando := v_conjunto_total;
    v_numero_ciclo := 0;
    v_abertura := null;

    for v_concurso in
      select concurso, dezenas from concursos order by concurso asc
    loop
      if v_abertura is null then
        v_abertura := v_concurso.concurso;
      end if;

      -- remove da lista de faltantes as dezenas da categoria que saíram agora
      select array_agg(d) into v_faltando
      from unnest(v_faltando) d
      where not (d = any(v_concurso.dezenas));

      if v_faltando is null or array_length(v_faltando,1) is null then
        -- ciclo fechou neste concurso
        v_numero_ciclo := v_numero_ciclo + 1;

        insert into ciclos_fechados
          (categoria, numero_ciclo, concurso_abertura, concurso_fechamento, qtd_concursos)
        values (
          v_categoria, v_numero_ciclo, v_abertura, v_concurso.concurso,
          v_concurso.concurso - v_abertura + 1
        );

        -- reinicia o ciclo
        v_faltando := v_conjunto_total;
        v_abertura := null;
      end if;
    end loop;

  end loop;
end;
$$;

-- Estado do ciclo ABERTO (em andamento) por categoria: quais dezenas ainda
-- faltam sair, e desde qual concurso o ciclo está aberto.
create or replace function ciclo_aberto_status()
returns table (
  categoria             text,
  concurso_abertura     int,
  concursos_decorridos  int,
  dezenas_faltando      int[],
  qtd_faltando          int
) language plpgsql as $$
declare
  v_categoria       text;
  v_conjunto_total  int[];
  v_faltando        int[];
  v_concurso        record;
  v_abertura        int;
  v_ultimo_concurso int;
begin
  for v_categoria in select distinct categoria from categorias_numeros loop

    select array_agg(dezena order by dezena) into v_conjunto_total
    from categorias_numeros where categoria = v_categoria;

    v_faltando := v_conjunto_total;
    v_abertura := null;

    for v_concurso in
      select c.concurso, c.dezenas from concursos c order by c.concurso asc
    loop
      if v_abertura is null then
        v_abertura := v_concurso.concurso;
      end if;

      select array_agg(d) into v_faltando
      from unnest(v_faltando) d
      where not (d = any(v_concurso.dezenas));

      if v_faltando is null or array_length(v_faltando,1) is null then
        v_faltando := v_conjunto_total;
        v_abertura := null;
      end if;

      v_ultimo_concurso := v_concurso.concurso;
    end loop;

    categoria := v_categoria;
    concurso_abertura := v_abertura;
    concursos_decorridos := coalesce(v_ultimo_concurso - v_abertura + 1, 0);
    dezenas_faltando := v_faltando;
    qtd_faltando := coalesce(array_length(v_faltando,1), 0);
    return next;
  end loop;
end;
$$;

-- View pronta pra consultar no dashboard: "quais dezenas estão atrasadas agora"
create or replace view dezenas_atrasadas as
select * from ciclo_aberto_status() order by qtd_faltando asc, categoria;

-- Estatística útil: duração média (em concursos) de cada categoria pra fechar o ciclo
create or replace view duracao_media_ciclos as
select categoria,
       count(*) as ciclos_fechados,
       round(avg(qtd_concursos),1) as media_concursos,
       min(qtd_concursos) as minimo,
       max(qtd_concursos) as maximo
from ciclos_fechados
group by categoria
order by categoria;
