-- =====================================================================
-- CAVERNA DE PLATÃO — Esquema PostgreSQL (Supabase, PG15+)
-- Execute no SQL Editor ou como migration: supabase/migrations/0001_init.sql
--
-- Princípios:
--  1. Toda tabela de dados tem user_id e RLS ativa (auth.uid() = user_id).
--  2. Relações entre registros usam FK composta (id, user_id): impossível
--     apontar para dado de outro usuário, mesmo com chamadas diretas à API.
--  3. Um único registro por tarefa/evento; seções apenas o consultam.
--  4. Anti-duplicidade no banco: sessões de estudo e páginas lidas não
--     podem se sobrepor (exclusion constraints).
-- =====================================================================

create extension if not exists btree_gist;

-- ---------- utilitários ----------
create or replace function public.set_updated_at() returns trigger
language plpgsql as $$ begin new.updated_at = now(); return new; end $$;

-- ---------- perfil e preferências ----------
create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text,
  avatar_path text,
  timezone text not null default 'America/Boa_Vista',
  locale text not null default 'pt-BR',
  week_start smallint not null default 0 check (week_start between 0 and 6),
  date_format text not null default 'dd/MM/yyyy',
  time_format text not null default '24h' check (time_format in ('12h','24h')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.user_preferences (
  user_id uuid primary key references auth.users(id) on delete cascade,
  theme text not null default 'classic',           -- classic | night | contrast | custom:<id>
  custom_palette jsonb not null default '{}',
  density text not null default 'comfortable',
  reduce_motion boolean not null default false,
  agora_layout jsonb not null default '[]',        -- ordem/visibilidade dos módulos
  reader_prefs jsonb not null default '{}',
  review_prefs jsonb not null default '{}',        -- limites diários, algoritmo
  notification_prefs jsonb not null default '{}',
  email_reminders_consent boolean not null default false,
  reminder_email text,
  ai_consent boolean not null default false,       -- consentimento explícito p/ IA
  updated_at timestamptz not null default now()
);

create table public.custom_themes (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  name text not null,
  palette jsonb not null,
  created_at timestamptz not null default now(),
  unique (id, user_id)
);

-- cria perfil + preferências no cadastro
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles(id, display_name)
    values (new.id, coalesce(new.raw_user_meta_data->>'display_name', split_part(new.email,'@',1)));
  insert into public.user_preferences(user_id) values (new.id);
  return new;
end $$;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------- disciplinas / assuntos (compartilhadas por vários módulos) ----------
create table public.subjects (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  name text not null,
  kind text not null default 'course' check (kind in ('course','residency','personal')),
  color text,
  archived boolean not null default false,
  created_at timestamptz not null default now(),
  unique (id, user_id)
);

-- ---------- calendário ----------
create table public.events (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  title text not null,
  description text,
  starts_at timestamptz not null,
  ends_at timestamptz,
  all_day boolean not null default false,
  rrule text,                                      -- RFC 5545 (ex.: FREQ=WEEKLY;BYDAY=MO)
  rrule_until timestamptz,
  category text, color text, cover_path text,
  location text, meeting_url text,
  priority smallint not null default 2 check (priority between 1 and 3),
  kind text not null default 'personal'
    check (kind in ('personal','class','study','tutoring','extracurricular','exam')),
  subject_id uuid,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (ends_at is null or ends_at >= starts_at),
  unique (id, user_id),
  foreign key (subject_id, user_id) references public.subjects(id, user_id) on delete set null (subject_id)
);
-- exceções e remarcações de UMA ocorrência, sem duplicar nem apagar histórico
create table public.event_overrides (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  event_id uuid not null,
  original_start timestamptz not null,
  new_start timestamptz, new_end timestamptz,
  cancelled boolean not null default false,
  completed_at timestamptz,
  unique (event_id, original_start),
  foreign key (event_id, user_id) references public.events(id, user_id) on delete cascade
);

-- ---------- hábitos ----------
create table public.habits (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  name text not null, icon text, color text,
  type text not null default 'binary' check (type in ('binary','quantity')),
  unit text,
  target numeric,                                   -- meta por período
  target_period text not null default 'day' check (target_period in ('day','week')),
  weekdays smallint[] not null default '{0,1,2,3,4,5,6}',  -- dias ativos; os demais = descanso
  preferred_time time,
  notes text,
  archived boolean not null default false,
  created_at timestamptz not null default now(),
  unique (id, user_id)
);
create table public.habit_logs (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  habit_id uuid not null,
  log_date date not null,
  value numeric not null default 1,
  note text,
  unique (habit_id, log_date),
  foreign key (habit_id, user_id) references public.habits(id, user_id) on delete cascade
);
create table public.workouts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  modality text not null,
  started_at timestamptz not null,
  duration_min integer check (duration_min > 0),
  distance_km numeric check (distance_km >= 0),
  notes text
);

-- ---------- tarefas (registro único) ----------
create table public.tasks (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  title text not null,
  description text,
  due_date date,
  start_time time, end_time time,
  priority smallint not null default 2 check (priority between 1 and 3),
  category text, color text,
  est_minutes integer check (est_minutes > 0),
  rrule text,
  completed_at timestamptz,                         -- nulo = pendente
  subject_id uuid, habit_id uuid, event_id uuid,
  notes text,
  reschedule_count integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (id, user_id),
  foreign key (subject_id, user_id) references public.subjects(id, user_id) on delete set null (subject_id),
  foreign key (habit_id, user_id) references public.habits(id, user_id) on delete set null (habit_id),
  foreign key (event_id, user_id) references public.events(id, user_id) on delete set null (event_id)
);
-- histórico de reprogramação: mudar a data nunca apaga a conclusão anterior
create table public.task_history (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  task_id uuid not null,
  action text not null check (action in ('created','rescheduled','completed','reopened')),
  old_date date, new_date date,
  at timestamptz not null default now(),
  foreign key (task_id, user_id) references public.tasks(id, user_id) on delete cascade
);
create table public.reminders (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  task_id uuid, event_id uuid,
  minutes_before integer not null check (minutes_before >= 0),
  channel text not null default 'in_app' check (channel in ('in_app','browser','email')),
  check (num_nonnulls(task_id, event_id) = 1),
  foreign key (task_id, user_id) references public.tasks(id, user_id) on delete cascade,
  foreign key (event_id, user_id) references public.events(id, user_id) on delete cascade
);
create table public.notification_log (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  reminder_id uuid references public.reminders(id) on delete set null,
  channel text not null, scheduled_for timestamptz not null,
  sent_at timestamptz, status text not null default 'pending'
    check (status in ('pending','sent','failed','skipped')),
  error text,
  unique (reminder_id, scheduled_for)               -- impede envio duplicado
);

-- ---------- estudo: metas e sessões ----------
create table public.study_goals (
  user_id uuid not null references auth.users(id) on delete cascade,
  weekday smallint not null check (weekday between 0 and 6),
  minutes integer not null check (minutes >= 0),
  primary key (user_id, weekday)
);
create table public.study_goal_periods (            -- provas, férias
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  label text not null, starts_on date not null, ends_on date not null,
  minutes integer not null check (minutes >= 0), check (ends_on >= starts_on)
);
create table public.study_sessions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  subject_id uuid, task_id uuid,
  started_at timestamptz not null,
  ended_at timestamptz,                              -- nulo = em andamento
  active_seconds integer not null default 0 check (active_seconds >= 0),
  status text not null default 'running' check (status in ('running','paused','finished')),
  foreign key (subject_id, user_id) references public.subjects(id, user_id) on delete set null (subject_id),
  foreign key (task_id, user_id) references public.tasks(id, user_id) on delete set null (task_id),
  -- sessões do mesmo usuário não podem se sobrepor: sem contagem dupla
  exclude using gist (user_id with =, tstzrange(started_at, ended_at) with &&)
);
-- no máximo UMA sessão em andamento por usuário
create unique index one_open_session on public.study_sessions(user_id) where ended_at is null;

-- ---------- flashcards (compatível com Anki / FSRS) ----------
create table public.decks (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  parent_id uuid,
  name text not null,
  subject_id uuid,
  options jsonb not null default '{}',               -- limites diários, learning steps, retenção
  anki_id bigint,
  unique (id, user_id),
  foreign key (parent_id, user_id) references public.decks(id, user_id) on delete cascade,
  foreign key (subject_id, user_id) references public.subjects(id, user_id) on delete set null (subject_id)
);
create table public.note_types (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  name text not null, fields text[] not null, templates jsonb not null, css text,
  is_cloze boolean not null default false, anki_id bigint,
  unique (id, user_id)
);
create table public.notes (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  note_type_id uuid not null,
  fields jsonb not null,                             -- {"Frente": "<html>", "Verso": "..."}
  tags text[] not null default '{}',
  anki_guid text,
  created_at timestamptz not null default now(),
  unique (id, user_id),
  foreign key (note_type_id, user_id) references public.note_types(id, user_id)
);
create unique index notes_anki_guid on public.notes(user_id, anki_guid) where anki_guid is not null; -- reimportar não duplica
create table public.cards (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  note_id uuid not null, deck_id uuid not null,
  template_ord smallint not null default 0,
  -- estado de agendamento (FSRS)
  state smallint not null default 0 check (state between 0 and 3), -- 0 novo,1 aprendendo,2 revisão,3 reaprendendo
  due timestamptz not null default now(),
  stability real, difficulty real,
  scheduled_days integer not null default 0,
  reps integer not null default 0, lapses integer not null default 0,
  last_review timestamptz,
  suspended boolean not null default false, flagged smallint not null default 0,
  anki_ivl integer, anki_factor integer,            -- valores originais, para relatório de conversão
  unique (id, user_id),
  foreign key (note_id, user_id) references public.notes(id, user_id) on delete cascade,
  foreign key (deck_id, user_id) references public.decks(id, user_id) on delete cascade
);
create index cards_due on public.cards(user_id, due) where not suspended;
create table public.review_logs (                    -- fonte única de verdade do gráfico de constância
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  card_id uuid not null,
  rating smallint not null check (rating between 1 and 4),  -- 1 Novamente,2 Difícil,3 Bom,4 Fácil
  state_before smallint not null, due_before timestamptz,
  stability_before real, difficulty_before real,
  duration_ms integer, reviewed_at timestamptz not null default now(),
  foreign key (card_id, user_id) references public.cards(id, user_id) on delete cascade
);
create index review_logs_day on public.review_logs(user_id, reviewed_at);
create table public.media_assets (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  note_id uuid, filename text not null, storage_path text not null, mime text,
  foreign key (note_id, user_id) references public.notes(id, user_id) on delete cascade
);
create table public.import_reports (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  source text not null, filename text,
  converted integer not null default 0, skipped integer not null default 0,
  details jsonb not null default '{}',               -- itens ignorados / precisam de correção
  created_at timestamptz not null default now()
);

-- ---------- residência médica ----------
create table public.exam_processes (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  institution text not null, specialty text, entry_year integer, exam_date date,
  stages jsonb not null default '[]', bibliography text, status text,
  notice_path text,
  unique (id, user_id)
);
create table public.syllabus_items (                 -- área → disciplina → assunto → subassunto
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  process_id uuid not null, parent_id uuid,
  level smallint not null check (level between 1 and 4),
  title text not null, position integer not null default 0,
  weight numeric not null default 1 check (weight >= 0),
  status text not null default 'not_started' check (status in ('not_started','in_progress','done')),
  priority smallint not null default 2, planned_date date, completed_at date,
  self_mastery smallint check (self_mastery between 0 and 5),
  notes text,
  unique (id, user_id),
  foreign key (process_id, user_id) references public.exam_processes(id, user_id) on delete cascade,
  foreign key (parent_id, user_id) references public.syllabus_items(id, user_id) on delete cascade
);
create table public.question_logs (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  syllabus_item_id uuid, question_bank text, organizer text, exam_year integer,
  total integer not null check (total >= 0), correct integer not null check (correct >= 0),
  time_spent_min integer, error_notes text, solved_on date not null default current_date,
  check (correct <= total),
  foreign key (syllabus_item_id, user_id) references public.syllabus_items(id, user_id) on delete set null (syllabus_item_id)
);

-- ---------- faculdade ----------
create table public.courses (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  subject_id uuid not null, professor text, semester text, syllabus text,
  objectives text, bibliography text,
  grade_formula text,                                -- fórmula definida pelo usuário
  unique (id, user_id),
  foreign key (subject_id, user_id) references public.subjects(id, user_id) on delete cascade
);
create table public.assessments (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  course_id uuid not null, name text not null,
  weight numeric not null default 1, grade numeric, max_grade numeric not null default 10,
  due_date date,
  foreign key (course_id, user_id) references public.courses(id, user_id) on delete cascade
);

-- ---------- biblioteca ----------
create table public.books (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  title text not null, author text, publisher text, language text, identifier text,
  genre text, cover_path text, file_path text, toc jsonb,
  status text not null default 'wishlist' check (status in ('wishlist','to_read','reading','finished')),
  rating smallint check (rating between 1 and 5), total_pages integer,
  started_on date, finished_on date, processing_state text not null default 'pending',
  created_at timestamptz not null default now(),
  unique (id, user_id)
);
create table public.book_chapters (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  book_id uuid not null, position integer not null, title text, href text, text_content text,
  foreign key (book_id, user_id) references public.books(id, user_id) on delete cascade
);
create table public.collections (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  name text not null, unique (id, user_id)
);
create table public.collection_books (
  user_id uuid not null references auth.users(id) on delete cascade,
  collection_id uuid not null, book_id uuid not null,
  primary key (collection_id, book_id),
  foreign key (collection_id, user_id) references public.collections(id, user_id) on delete cascade,
  foreign key (book_id, user_id) references public.books(id, user_id) on delete cascade
);
create table public.reading_positions (
  user_id uuid not null references auth.users(id) on delete cascade,
  book_id uuid not null, cfi text, chapter_position integer, percent numeric,
  updated_at timestamptz not null default now(),
  primary key (user_id, book_id),
  foreign key (book_id, user_id) references public.books(id, user_id) on delete cascade
);
create table public.reading_logs (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  book_id uuid not null, read_on date not null default current_date,
  start_page integer not null check (start_page >= 0),
  end_page integer not null,
  pages integer generated always as (end_page - start_page + 1) stored,
  pass smallint not null default 1,                  -- releituras usam outra "passada"
  minutes integer check (minutes >= 0), comment text,
  check (end_page >= start_page),
  foreign key (book_id, user_id) references public.books(id, user_id) on delete cascade,
  -- páginas sobrepostas no mesmo livro/passada não são somadas duas vezes
  exclude using gist (book_id with =, pass with =, int4range(start_page, end_page, '[]') with &&)
);
create table public.annotations (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  book_id uuid not null, kind text not null check (kind in ('bookmark','highlight','note')),
  cfi text, quote text, note text, color text,
  created_at timestamptz not null default now(),
  foreign key (book_id, user_id) references public.books(id, user_id) on delete cascade
);
create table public.summaries (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  book_id uuid not null, depth text not null, content jsonb not null,
  ai_generated boolean not null default true, model text,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  foreign key (book_id, user_id) references public.books(id, user_id) on delete cascade
);
create table public.processing_jobs (                -- retomável e idempotente
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  book_id uuid, kind text not null,
  status text not null default 'queued' check (status in ('queued','running','done','failed')),
  progress jsonb not null default '{}', idempotency_key text, error text,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  unique (user_id, idempotency_key),
  foreign key (book_id, user_id) references public.books(id, user_id) on delete cascade
);

-- ---------- diário (privado) ----------
create table public.journal_entries (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  title text, body text not null default '', mood smallint check (mood between 1 and 5),
  tags text[] not null default '{}', book_id uuid, entry_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (book_id, user_id) references public.books(id, user_id) on delete set null (book_id)
);
create table public.journal_revisions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  entry_id uuid not null references public.journal_entries(id) on delete cascade,
  body text not null, saved_at timestamptz not null default now()
);

-- ---------- triggers updated_at ----------
do $$ declare t text; begin
  foreach t in array array['profiles','user_preferences','events','tasks','summaries','processing_jobs','journal_entries','reading_positions']
  loop execute format('create trigger %I_upd before update on public.%I for each row execute function public.set_updated_at()', t, t); end loop;
end $$;

-- ---------- RLS: ativa e cria política "somente o dono" em TODAS as tabelas ----------
do $$ declare t record; begin
  for t in
    select c.table_name,
           exists(select 1 from information_schema.columns k
                  where k.table_schema='public' and k.table_name=c.table_name and k.column_name='user_id') as has_uid
    from information_schema.tables c where c.table_schema='public' and c.table_type='BASE TABLE'
  loop
    execute format('alter table public.%I enable row level security', t.table_name);
    if t.table_name = 'profiles' then
      execute 'create policy own on public.profiles for all to authenticated
               using (id = (select auth.uid())) with check (id = (select auth.uid()))';
    elsif t.has_uid then
      execute format('create policy own on public.%I for all to authenticated
               using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()))', t.table_name);
    end if;
  end loop;
end $$;

-- ---------- Storage: buckets PRIVADOS, pasta = id do usuário ----------
insert into storage.buckets(id, name, public, file_size_limit) values
  ('books','books',false, 104857600),
  ('imports','imports',false, 524288000),
  ('materials','materials',false, 104857600),
  ('covers','covers',false, 10485760),
  ('avatars','avatars',false, 5242880)
on conflict (id) do nothing;

create policy "own files read" on storage.objects for select to authenticated
  using (bucket_id in ('books','imports','materials','covers','avatars')
         and (storage.foldername(name))[1] = (select auth.uid())::text);
create policy "own files write" on storage.objects for insert to authenticated
  with check (bucket_id in ('books','imports','materials','covers','avatars')
         and (storage.foldername(name))[1] = (select auth.uid())::text);
create policy "own files update" on storage.objects for update to authenticated
  using ((storage.foldername(name))[1] = (select auth.uid())::text);
create policy "own files delete" on storage.objects for delete to authenticated
  using ((storage.foldername(name))[1] = (select auth.uid())::text);

-- ---------- Views derivadas (números reais, nunca fictícios) ----------
create view public.v_daily_review_counts with (security_invoker = true) as
  select user_id, (reviewed_at at time zone p.timezone)::date as day, count(*) as reviews
  from public.review_logs r join public.profiles p on p.id = r.user_id
  group by 1, 2;

create view public.v_daily_study_minutes with (security_invoker = true) as
  select s.user_id, (s.started_at at time zone p.timezone)::date as day,
         round(sum(s.active_seconds) / 60.0, 1) as minutes
  from public.study_sessions s join public.profiles p on p.id = s.user_id
  group by 1, 2;

create view public.v_syllabus_progress with (security_invoker = true) as
  select process_id, user_id,
         count(*) filter (where level = 4 or not exists (select 1 from public.syllabus_items c where c.parent_id = i.id)) as leaves,
         sum(weight) filter (where status = 'done') as done_weight,
         sum(weight) as total_weight,
         round(100 * coalesce(sum(weight) filter (where status = 'done'),0) / nullif(sum(weight),0), 1) as pct_weighted
  from public.syllabus_items i
  where not exists (select 1 from public.syllabus_items c where c.parent_id = i.id)  -- só folhas
  group by process_id, user_id;
