-- Players share how they feel after today's meditation; the pet answers with an AI-written, in-character note.
create table if not exists public.mood_entries (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  pet_id uuid not null references public.pets(id) on delete cascade,
  day date not null,
  mood text not null check (mood in ('calm','happy','grateful','tired','anxious','sad','stressed','lonely')),
  note text check (note is null or char_length(note) <= 280),
  reply text check (reply is null or char_length(reply) <= 600),
  created_at timestamptz not null default now(),
  replied_at timestamptz
);
create index if not exists mood_entries_user_idx on public.mood_entries(user_id, created_at desc);
create index if not exists mood_entries_pet_idx on public.mood_entries(pet_id);
alter table public.mood_entries enable row level security;
drop policy if exists "read own moods" on public.mood_entries;
create policy "read own moods" on public.mood_entries for select to authenticated using ((select auth.uid()) = user_id);
revoke insert, update, delete, truncate on public.mood_entries from anon, authenticated;
revoke all on public.mood_entries from anon;

-- save_mood: only after today's meditation, at most 3 per day; returns entry id + pet context for the AI.
create or replace function public.save_mood(p_mood text, p_note text default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid(); t date; p public.pets; c public.daily_checkins; n int; e public.mood_entries; note text;
begin
  if uid is null then raise exception 'Not signed in'; end if;
  if p_mood not in ('calm','happy','grateful','tired','anxious','sad','stressed','lonely') then raise exception 'Unknown mood'; end if;
  note := nullif(btrim(coalesce(p_note, '')), '');
  if note is not null and char_length(note) > 280 then raise exception 'Keep it under 280 characters'; end if;
  t := private.today_for(uid);
  select * into p from public.pets where user_id = uid and retired_at is null;
  if p.id is null or not p.alive then raise exception 'No living pet'; end if;
  select * into c from public.daily_checkins where pet_id = p.id and day = t;
  if c.pet_id is null or not c.meditate then raise exception 'Finish today''s meditation first'; end if;
  select count(*) into n from public.mood_entries where user_id = uid and day = t;
  if n >= 3 then raise exception 'You have shared your mood 3 times today. Come back tomorrow.'; end if;
  insert into public.mood_entries(user_id, pet_id, day, mood, note) values (uid, p.id, t, p_mood, note) returning * into e;
  return jsonb_build_object(
    'entry_id', e.id, 'mood', e.mood, 'note', e.note, 'day', t,
    'pet', jsonb_build_object(
      'name', p.name, 'species', p.species, 'happiness', p.happiness, 'fruits', p.fruits,
      'streak', case when p.last_valid_day is not null and t - p.last_valid_day <= 1 then p.streak else 0 end,
      'absent_days', greatest(0, t - p.last_checkin_day - 1), 'rescues', p.rescues));
end $$;

-- set_mood_reply: store the pet's reply once, for an entry the caller owns.
create or replace function public.set_mood_reply(p_entry_id uuid, p_reply text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid(); e public.mood_entries; r text;
begin
  if uid is null then raise exception 'Not signed in'; end if;
  r := btrim(coalesce(p_reply, ''));
  if r = '' then raise exception 'Empty reply'; end if;
  if char_length(r) > 600 then r := left(r, 600); end if;
  update public.mood_entries set reply = r, replied_at = now()
   where id = p_entry_id and user_id = uid and reply is null
  returning * into e;
  if e.id is null then raise exception 'Entry not found or already answered'; end if;
  return jsonb_build_object('entry_id', e.id, 'reply', e.reply);
end $$;

revoke all on function public.save_mood(text, text), public.set_mood_reply(uuid, text) from public, anon;
grant execute on function public.save_mood(text, text), public.set_mood_reply(uuid, text) to authenticated;
