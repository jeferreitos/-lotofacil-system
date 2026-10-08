-- ============================================================
-- LOTOFÁCIL SYSTEM · Migration 0007: acesso só com login
--
-- Antes: as regras de RLS liberavam leitura, cadastro, alteração e
-- exclusão pra qualquer visitante do site (papel "anon").
-- Agora: só usuários logados E cadastrados em "usuarios_autorizados"
-- leem ou alteram os dados. Visitante sem login não acessa nada.
--
-- Rodar SÓ DEPOIS de:
--   1) criar seu usuário em Authentication → Users → Add user
--   2) a versão nova do index.html (com tela de login) estar no ar
-- e em seguida liberar seu usuário com o insert do final do arquivo.
-- ============================================================

-- ------------------------------------------------------------
-- 1) Lista de usuários autorizados (sem acesso pela API)
-- ------------------------------------------------------------
create table if not exists usuarios_autorizados (
  user_id uuid primary key references auth.users(id) on delete cascade
);
alter table usuarios_autorizados enable row level security;

create or replace function eh_autorizado()
returns boolean language sql stable security definer set search_path to 'public' as $$
  select exists (select 1 from usuarios_autorizados where user_id = auth.uid())
$$;

-- ------------------------------------------------------------
-- 2) Remove as regras abertas pra visitantes
-- ------------------------------------------------------------
drop policy if exists "anon pode ler categorias_numeros"          on categorias_numeros;
drop policy if exists "anon pode ler ciclos_fechados"             on ciclos_fechados;
drop policy if exists "anon pode ler concursos"                   on concursos;
drop policy if exists "Permitir insert manual de concursos"       on concursos;
drop policy if exists "Permitir update manual de concursos"       on concursos;
drop policy if exists "Permitir leitura de jogos"                 on meus_jogos;
drop policy if exists "permitir insert publico em meus_jogos"     on meus_jogos;
drop policy if exists "Permitir exclusão de jogos"                on meus_jogos;
drop policy if exists "leitura publica"                           on ciclo_estado_hist;
drop policy if exists "leitura publica"                           on gerador_config;

-- ------------------------------------------------------------
-- 3) Regras novas: só usuário autorizado
-- ------------------------------------------------------------
drop policy if exists "autorizado le" on categorias_numeros;
create policy "autorizado le" on categorias_numeros for select to authenticated using (eh_autorizado());

drop policy if exists "autorizado le" on ciclos_fechados;
create policy "autorizado le" on ciclos_fechados for select to authenticated using (eh_autorizado());

drop policy if exists "autorizado le" on crivo_filtros;
create policy "autorizado le" on crivo_filtros for select to authenticated using (eh_autorizado());

drop policy if exists "autorizado le" on conferencias;
create policy "autorizado le" on conferencias for select to authenticated using (eh_autorizado());

drop policy if exists "autorizado tudo" on concursos;
create policy "autorizado tudo" on concursos for all to authenticated
  using (eh_autorizado()) with check (eh_autorizado());

drop policy if exists "autorizado tudo" on meus_jogos;
create policy "autorizado tudo" on meus_jogos for all to authenticated
  using (eh_autorizado()) with check (eh_autorizado());

-- ------------------------------------------------------------
-- 4) Views passam a respeitar as regras de quem consulta (por padrão o
--    Postgres executa a view como o dono e ignoraria o RLS)
-- ------------------------------------------------------------
alter view painel_conferencias        set (security_invoker = true);
alter view meus_jogos_metricas        set (security_invoker = true);
alter view dezenas_atrasadas          set (security_invoker = true);
alter view duracao_media_ciclos       set (security_invoker = true);
alter view atraso_dezenas_individual  set (security_invoker = true);
alter view faixas_aceitaveis          set (security_invoker = true);
alter view concursos_metricas_extra   set (security_invoker = true);
alter view vw_concursos_metricas      set (security_invoker = true);
alter view export_jogos_texto         set (security_invoker = true);
alter view export_jogos_csv           set (security_invoker = true);

-- ------------------------------------------------------------
-- 5) Visitante sem login não lê tabela/view nem chama função nenhuma
-- ------------------------------------------------------------
revoke all on all tables in schema public from anon;
revoke all on all sequences in schema public from anon;
revoke execute on all functions in schema public from public, anon;
grant execute on all functions in schema public to authenticated, service_role;

-- ------------------------------------------------------------
-- 6) Libere SEU usuário (troque pelo e-mail que você cadastrou em
--    Authentication → Users e rode esta linha separadamente):
--
-- insert into usuarios_autorizados (user_id)
-- select id from auth.users where email = 'SEU_EMAIL_AQUI'
-- on conflict do nothing;
-- ------------------------------------------------------------
