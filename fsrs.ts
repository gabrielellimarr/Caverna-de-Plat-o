/**
 * Caverna de Platão — módulo de repetição espaçada (FSRS-5)
 *
 * Independente de banco, rede e framework: funções puras, testáveis.
 * Algoritmo: FSRS-5 (19 parâmetros), curva de esquecimento R = (1 + F·t/S)^-0,5.
 * NÃO é o SM-2 do Anki clássico. Cartões importados de coleções SM-2 precisam
 * de conversão (ver docs no fim do arquivo). Sem "fuzz": o agendamento é
 * determinístico, o que facilita testes e reprodutibilidade.
 */

export enum Rating { Again = 1, Hard = 2, Good = 3, Easy = 4 }
export enum State { New = 0, Learning = 1, Review = 2, Relearning = 3 }

/** Pesos padrão do FSRS-5. Podem ser substituídos por pesos otimizados do usuário. */
export const DEFAULT_WEIGHTS: readonly number[] = [
  0.40255, 1.18385, 3.173, 15.69105, 7.1949, 0.5345, 1.4604, 0.0046, 1.54575,
  0.1192, 1.01925, 1.9395, 0.11, 0.29605, 2.2698, 0.2315, 2.9898, 0.51655, 0.6621,
];

export interface Params {
  weights: readonly number[];
  /** Retenção desejada (0,7–0,99). Padrão do Anki: 0,9. */
  requestRetention: number;
  maxIntervalDays: number;
  /** Passos de aprendizagem em minutos (novos cartões). */
  learningSteps: readonly number[];
  /** Passos de reaprendizagem em minutos (após lapso). */
  relearningSteps: readonly number[];
}

export const DEFAULT_PARAMS: Params = {
  weights: DEFAULT_WEIGHTS,
  requestRetention: 0.9,
  maxIntervalDays: 36500,
  learningSteps: [1, 10],
  relearningSteps: [10],
};

/** Espelha as colunas da tabela public.cards (mais learning_step, ver README). */
export interface CardState {
  state: State;
  due: Date;
  stability: number | null;
  difficulty: number | null;
  scheduledDays: number;
  reps: number;
  lapses: number;
  lastReview: Date | null;
  learningStep: number;
}

/** Espelha public.review_logs. */
export interface ReviewLog {
  rating: Rating;
  stateBefore: State;
  dueBefore: Date;
  stabilityBefore: number | null;
  difficultyBefore: number | null;
  reviewedAt: Date;
}

const F = 19 / 81;
const DECAY = -0.5;
const MS_MIN = 60_000;
const MS_DAY = 86_400_000;
const S_MIN = 0.01;

const clamp = (x: number, lo: number, hi: number) => Math.min(Math.max(x, lo), hi);
const clampD = (d: number) => clamp(d, 1, 10);

export function newCard(now: Date): CardState {
  return { state: State.New, due: now, stability: null, difficulty: null,
    scheduledDays: 0, reps: 0, lapses: 0, lastReview: null, learningStep: 0 };
}

/** Probabilidade de lembrar após t dias com estabilidade S. R(S,S) = 0,9. */
export function forgettingCurve(elapsedDays: number, stability: number): number {
  return Math.pow(1 + (F * Math.max(elapsedDays, 0)) / stability, DECAY);
}

/** Retrievability atual do cartão (0 se nunca revisado). */
export function retrievability(card: CardState, now: Date): number {
  if (card.stability == null || card.lastReview == null) return 0;
  return forgettingCurve((now.getTime() - card.lastReview.getTime()) / MS_DAY, card.stability);
}

/** Intervalo (dias) para atingir a retenção desejada. */
export function nextIntervalDays(stability: number, p: Params): number {
  const i = (stability / F) * (Math.pow(p.requestRetention, 1 / DECAY) - 1);
  return clamp(Math.round(i), 1, p.maxIntervalDays);
}

const initStability = (g: Rating, w: readonly number[]) => Math.max(w[g - 1], S_MIN);
const initDifficulty = (g: Rating, w: readonly number[]) =>
  clampD(w[4] - Math.exp(w[5] * (g - 1)) + 1);

function nextDifficulty(d: number, g: Rating, w: readonly number[]): number {
  const delta = -w[6] * (g - 3);
  const damped = d + (delta * (10 - d)) / 9;            // amortecimento linear
  const reverted = w[7] * initDifficulty(Rating.Easy, w) + (1 - w[7]) * damped; // reversão à média
  return clampD(reverted);
}

function nextRecallStability(d: number, s: number, r: number, g: Rating, w: readonly number[]): number {
  const hard = g === Rating.Hard ? w[15] : 1;
  const easy = g === Rating.Easy ? w[16] : 1;
  return s * (1 + Math.exp(w[8]) * (11 - d) * Math.pow(s, -w[9]) *
    (Math.exp((1 - r) * w[10]) - 1) * hard * easy);
}

function nextForgetStability(d: number, s: number, r: number, w: readonly number[]): number {
  const raw = w[11] * Math.pow(d, -w[12]) * (Math.pow(s + 1, w[13]) - 1) * Math.exp((1 - r) * w[14]);
  const ceiling = s / Math.exp(w[17] * w[18]);          // nunca maior que a estabilidade anterior
  return clamp(raw, S_MIN, Math.max(ceiling, S_MIN));
}

/** Revisão no mesmo dia (<1 dia desde a última): fórmula de curto prazo. */
function nextShortTermStability(s: number, g: Rating, w: readonly number[]): number {
  let inc = Math.exp(w[17] * (g - 3 + w[18]));
  if (g >= Rating.Good) inc = Math.max(inc, 1);          // acerto nunca reduz estabilidade
  return Math.max(s * inc, S_MIN);
}

export interface SchedulingResult { card: CardState; log: ReviewLog }

/**
 * Aplica uma resposta e devolve o novo estado + o registro para review_logs.
 * Função pura: não altera o cartão recebido.
 */
export function schedule(card: CardState, rating: Rating, now: Date,
                         p: Params = DEFAULT_PARAMS): SchedulingResult {
  const w = p.weights;
  const log: ReviewLog = {
    rating, stateBefore: card.state, dueBefore: card.due,
    stabilityBefore: card.stability, difficultyBefore: card.difficulty, reviewedAt: now,
  };
  const next: CardState = { ...card, lastReview: now, reps: card.reps + 1 };
  const elapsedDays = card.lastReview ? (now.getTime() - card.lastReview.getTime()) / MS_DAY : 0;

  // ----- atualiza memória (S, D) -----
  if (card.state === State.New || card.stability == null || card.difficulty == null) {
    next.stability = initStability(rating, w);
    next.difficulty = initDifficulty(rating, w);
  } else {
    const r = forgettingCurve(elapsedDays, card.stability);
    next.difficulty = nextDifficulty(card.difficulty, rating, w);
    if (elapsedDays < 1) {
      next.stability = nextShortTermStability(card.stability, rating, w);
    } else if (rating === Rating.Again) {
      next.stability = nextForgetStability(card.difficulty, card.stability, r, w);
    } else {
      next.stability = nextRecallStability(card.difficulty, card.stability, r, rating, w);
    }
  }

  // ----- decide estado e vencimento -----
  const toReview = () => {
    next.state = State.Review;
    next.learningStep = 0;
    next.scheduledDays = nextIntervalDays(next.stability!, p);
    next.due = new Date(now.getTime() + next.scheduledDays * MS_DAY);
  };
  const toStep = (st: State, steps: readonly number[], idx: number) => {
    next.state = st;
    next.learningStep = idx;
    next.scheduledDays = 0;
    next.due = new Date(now.getTime() + steps[idx] * MS_MIN);
  };

  if (card.state === State.Review) {
    if (rating === Rating.Again) {
      next.lapses = card.lapses + 1;
      if (p.relearningSteps.length) toStep(State.Relearning, p.relearningSteps, 0);
      else toReview();
    } else toReview();
  } else {
    // Novo, Aprendendo ou Reaprendendo
    const relearn = card.state === State.Relearning;
    const steps = relearn ? p.relearningSteps : p.learningSteps;
    const st = relearn ? State.Relearning : State.Learning;
    const cur = card.state === State.New ? 0 : card.learningStep;

    if (!steps.length || rating === Rating.Easy) toReview();
    else if (rating === Rating.Again) toStep(st, steps, 0);
    else if (rating === Rating.Hard) toStep(st, steps, Math.min(cur, steps.length - 1));
    else if (cur + 1 >= steps.length) toReview();                 // Bom no último passo gradua
    else toStep(st, steps, cur + 1);
  }
  return { card: next, log };
}

/** Pré-visualização dos 4 botões (ex.: "10 min", "3 d"), sem alterar o cartão. */
export function preview(card: CardState, now: Date, p: Params = DEFAULT_PARAMS):
    Record<Rating, { due: Date; label: string }> {
  const out = {} as Record<Rating, { due: Date; label: string }>;
  for (const g of [Rating.Again, Rating.Hard, Rating.Good, Rating.Easy]) {
    const due = schedule(card, g, now, p).card.due;
    out[g] = { due, label: formatInterval(due.getTime() - now.getTime()) };
  }
  return out;
}

export function formatInterval(ms: number): string {
  const min = ms / MS_MIN;
  if (min < 60) return `${Math.max(1, Math.round(min))} min`;
  const h = min / 60;
  if (h < 24) return `${Math.round(h)} h`;
  const d = h / 24;
  if (d < 30) return `${Math.round(d)} d`;
  if (d < 365) return `${(d / 30).toFixed(1).replace('.', ',')} mês`;
  return `${(d / 365).toFixed(1).replace('.', ',')} a`;
}

/** Cartão está vencido/pendente em `now`? (suspensos devem ser filtrados no SQL) */
export const isDue = (card: CardState, now: Date) => card.due.getTime() <= now.getTime();

/*
 * CONVERSÃO DE COLEÇÕES SM-2 (.apkg sem FSRS)
 * O Anki clássico guarda ivl (dias) e factor (‰). Não há estabilidade/dificuldade.
 * Estratégia recomendada para o importador (a implementar e documentar no relatório):
 *   stability  ≈ ivl (dias)  — por definição, S é o intervalo em que R = 90%
 *   difficulty ≈ heurística linear: factor 1300→10, 3000→1 (fora disso, limitar);
 *                valor neutro (≈5) se factor ausente. É APROXIMAÇÃO e deve constar no relatório.
 *   due, state, lapses, reps: copiados diretamente
 * Quando o Anki de origem já usa FSRS, S e D vêm no campo `data` do cartão e
 * podem ser copiados sem aproximação.
 */
