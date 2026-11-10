-- Mood check-in at any time of day: save_mood no longer needs today's meditation to be finished.
-- Still at most 3 moods per day. The result gains 'after_sit' (true when today's sit is done) so the reply can fit the moment.
create or replace function private.save_mood_impl(p_mood text, p_note text default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid(); t date; p public.pets; c public.daily_checkins; n int; e public.mood_entries; note text;
  is_guest boolean := coalesce((auth.jwt()->>'is_anonymous')::boolean, false);
begin
  if uid is null then raise exception 'Not signed in'; end if;
  if p_mood not in ('calm','happy','grateful','tired','anxious','sad','stressed','lonely') then raise exception 'Unknown mood'; end if;
  note := nullif(btrim(coalesce(p_note, '')), '');
  if note is not null and char_length(note) > 280 then raise exception 'Keep it under 280 characters'; end if;
  t := private.today_for(uid);
  select * into p from public.pets where user_id = uid and retired_at is null;
  if p.id is null or not p.alive then raise exception 'No living pet'; end if;
  select * into c from public.daily_checkins where pet_id = p.id and day = t;
  select count(*) into n from public.mood_entries where user_id = uid and day = t;
  if n >= 3 then raise exception 'You have shared your mood 3 times today. Come back tomorrow.'; end if;
  insert into public.mood_entries(user_id, pet_id, day, mood, note) values (uid, p.id, t, p_mood, note) returning * into e;
  return jsonb_build_object(
    'entry_id', e.id, 'mood', e.mood, 'note', e.note, 'day', t, 'guest', is_guest, 'after_sit', coalesce(c.meditate, false),
    'pet', jsonb_build_object(
      'name', p.name, 'species', p.species, 'happiness', p.happiness, 'fruits', p.fruits,
      'streak', case when p.last_valid_day is not null and t - p.last_valid_day <= 1 then p.streak else 0 end,
      'absent_days', greatest(0, t - p.last_checkin_day - 1), 'rescues', p.rescues));
end $$;
revoke all on function private.save_mood_impl(text, text) from public, anon, authenticated;
