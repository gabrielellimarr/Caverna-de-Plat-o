# Módulo FSRS — Caverna de Platão

Local sugerido no repositório: `src/lib/fsrs/` (`fsrs.ts`, `fsrs.test.ts`).

## Rodar os testes
    npx tsx --test src/lib/fsrs/fsrs.test.ts

## Antes de usar com o banco
Este módulo precisa de uma coluna que o esquema inicial não tem. Rode no SQL Editor
(e salve como `supabase/migrations/0002_learning_step.sql`):

    alter table public.cards add column learning_step smallint not null default 0;

## Mapeamento com `public.cards`
state, due, stability, difficulty, scheduled_days, reps, lapses, last_review, learning_step
↔ CardState. Cada resposta gera um ReviewLog → `public.review_logs`.

## Limites (leia)
- Algoritmo: FSRS-5 (19 pesos). Anki 25.x usa FSRS-6 (21 pesos); resultados podem divergir levemente.
- Fórmulas escritas a partir da especificação pública, SEM comparação com a implementação de
  referência (ts-fsrs). Os testes verificam propriedades (R(S)=0,9; monotonicidade; limites),
  não valores numéricos de referência. Valide contra ts-fsrs antes de confiar nos intervalos.
- Sem fuzz de intervalos e sem otimização de pesos por usuário (usa os pesos padrão).
- Limites diários de cartões novos/revisões ficam na camada de consulta, não aqui.
