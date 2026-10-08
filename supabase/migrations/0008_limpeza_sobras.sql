-- ============================================================
-- LOTOFÁCIL SYSTEM · Migration 0008: remove sobras de versões antigas
--
-- Nada disto é usado pelo painel, pela Edge Function nem pelas outras
-- funções do banco. Sem "cascade": se algo inesperado depender de um
-- destes objetos, o Postgres recusa e nada é apagado.
-- ============================================================

-- views antigas do gerador por pesos (a final depende das outras duas)
drop view if exists dezena_peso_final;
drop view if exists dezena_peso_janela20;
drop view if exists dezena_peso_ciclo;

-- views de estatística de ciclos que a página não mostra
drop view if exists ciclo_duracao_dist;
drop view if exists ciclo_duracao_stats;
drop view if exists crivo_distribuicao;

-- geradores antigos (gerar_jogo chamava uma versão de
-- sortear_dezenas_ponderado que nem existe mais)
drop function if exists gerar_jogo(integer);
drop function if exists gerar_jogo_interno(numeric[], numeric[], numeric[], numeric[], numeric[], numeric[], numeric[], numeric[], numeric[], integer[], integer, boolean[], boolean[], boolean[], boolean[], boolean[], boolean[], integer[], numeric[]);
drop function if exists gerar_jogos_v1_backup(integer);
drop function if exists sortear_dezenas_ponderado(integer[], numeric[]);
drop function if exists faixa_aceitavel(text);
drop function if exists ciclo_hazard(text, integer, integer);
drop function if exists atualizar_ciclo_estado_hist();

-- tabelas antigas
drop table if exists ciclo_estado_hist;
drop table if exists gerador_config;
drop table if exists v_ultimo;
