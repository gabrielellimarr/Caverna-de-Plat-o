import { test } from 'node:test';
import assert from 'node:assert/strict';
import { Rating as R, State, newCard, schedule, forgettingCurve, nextIntervalDays,
         DEFAULT_PARAMS as P, retrievability, preview, isDue } from './fsrs.ts';

const t0 = new Date('2026-10-11T12:00:00Z');
const days = (d: number) => new Date(t0.getTime() + d * 86_400_000);
const mins = (m: number) => new Date(t0.getTime() + m * 60_000);

test('R(t=S) = 0,9 (definição de estabilidade)', () => {
  for (const s of [0.5, 1, 7, 100]) assert.ok(Math.abs(forgettingCurve(s, s) - 0.9) < 1e-9);
});

test('intervalo com retenção 0,9 ≈ estabilidade', () => {
  for (const s of [3, 10, 50]) assert.equal(nextIntervalDays(s, P), Math.round(s));
});

test('retenção maior => intervalo menor', () => {
  assert.ok(nextIntervalDays(30, { ...P, requestRetention: 0.95 }) < nextIntervalDays(30, P));
});

test('cartão novo: Again/Hard/Good ficam em aprendizagem; Easy gradua', () => {
  const c = newCard(t0);
  assert.equal(schedule(c, R.Again, t0).card.state, State.Learning);
  assert.equal(schedule(c, R.Hard, t0).card.state, State.Learning);
  assert.equal(schedule(c, R.Good, t0).card.state, State.Learning);
  const easy = schedule(c, R.Easy, t0).card;
  assert.equal(easy.state, State.Review);
  assert.ok(easy.scheduledDays >= 1);
});

test('passos de aprendizagem 1 min → 10 min → graduação', () => {
  let c = schedule(newCard(t0), R.Good, t0).card;
  assert.equal(c.learningStep, 1);
  assert.equal((c.due.getTime() - t0.getTime()) / 60_000, 10);
  c = schedule(c, R.Good, mins(10)).card;
  assert.equal(c.state, State.Review);
  assert.ok(c.scheduledDays >= 1);
});

test('estabilidade inicial segue w[rating-1]', () => {
  for (const g of [R.Again, R.Hard, R.Good, R.Easy])
    assert.equal(schedule(newCard(t0), g, t0).card.stability, P.weights[g - 1]);
});

test('dificuldade inicial decresce de Again para Easy e fica em [1,10]', () => {
  const d = [R.Again, R.Hard, R.Good, R.Easy].map(g => schedule(newCard(t0), g, t0).card.difficulty!);
  assert.ok(d[0] > d[1] && d[1] > d[2] && d[2] > d[3]);
  d.forEach(x => assert.ok(x >= 1 && x <= 10));
});

function graduated() { return schedule(newCard(t0), R.Easy, t0).card; }

test('revisão no vencimento: Easy ≥ Good ≥ Hard em estabilidade e intervalo', () => {
  const c = graduated(); const now = c.due;
  const [h, g, e] = [R.Hard, R.Good, R.Easy].map(r => schedule(c, r, now).card);
  assert.ok(e.stability! > g.stability! && g.stability! > h.stability!);
  assert.ok(e.scheduledDays >= g.scheduledDays && g.scheduledDays >= h.scheduledDays);
});

test('acertar aumenta a estabilidade; errar a reduz', () => {
  const c = graduated(); const now = c.due;
  assert.ok(schedule(c, R.Good, now).card.stability! > c.stability!);
  assert.ok(schedule(c, R.Again, now).card.stability! < c.stability!);
});

test('lapso: Again em revisão => Reaprendendo, +1 lapso, vence em minutos', () => {
  const c = graduated(); const now = c.due;
  const r = schedule(c, R.Again, now).card;
  assert.equal(r.state, State.Relearning);
  assert.equal(r.lapses, 1);
  assert.equal((r.due.getTime() - now.getTime()) / 60_000, 10);
});

test('dificuldade sobe com Again, desce com Easy, sempre em [1,10]', () => {
  let c = graduated(); const d0 = c.difficulty!;
  assert.ok(schedule(c, R.Again, c.due).card.difficulty! > d0);
  assert.ok(schedule(c, R.Easy, c.due).card.difficulty! < d0);
  for (let i = 0; i < 50; i++) { c = schedule(c, R.Again, c.due).card; assert.ok(c.difficulty! <= 10 && c.difficulty! >= 1); }
});

test('revisar antes do prazo rende menos estabilidade que no prazo', () => {
  const c = graduated();
  const early = schedule(c, R.Good, new Date(c.lastReview!.getTime() + 0.2 * c.scheduledDays * 86_400_000)).card;
  const onTime = schedule(c, R.Good, c.due).card;
  assert.ok(early.stability! < onTime.stability!);
});

test('função pura: não altera o cartão original', () => {
  const c = graduated(); const snap = JSON.stringify(c);
  schedule(c, R.Good, c.due);
  assert.equal(JSON.stringify(c), snap);
});

test('log registra o estado ANTES da resposta', () => {
  const c = graduated(); const { log } = schedule(c, R.Hard, c.due);
  assert.equal(log.stateBefore, State.Review);
  assert.equal(log.stabilityBefore, c.stability);
  assert.equal(log.rating, R.Hard);
});

test('intervalo respeita o máximo configurado', () => {
  assert.equal(nextIntervalDays(1e6, { ...P, maxIntervalDays: 365 }), 365);
});

test('preview não altera o cartão e devolve 4 botões ordenados', () => {
  const c = graduated(); const snap = JSON.stringify(c);
  const p = preview(c, c.due);
  assert.equal(JSON.stringify(c), snap);
  assert.ok(p[R.Again].due < p[R.Hard].due || p[R.Again].due <= p[R.Hard].due);
  assert.ok(p[R.Good].due <= p[R.Easy].due);
});

test('isDue e retrievability', () => {
  const c = graduated();
  assert.equal(isDue(c, days(0)), false);
  assert.equal(isDue(c, c.due), true);
  assert.ok(Math.abs(retrievability(c, c.due) - 0.9) < 0.02);
  assert.equal(retrievability(newCard(t0), t0), 0);
});
