-- Permite cadastrar jogos para um concurso que ainda não existe na tabela "concursos"
-- (o próximo concurso ainda não foi sorteado, então não pode ser chave estrangeira).
alter table meus_jogos
  drop constraint if exists meus_jogos_concurso_alvo_fkey;
