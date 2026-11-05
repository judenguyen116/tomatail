-- Pet adventures: finishing all four tasks sends the pet off for 6 hours.
-- Story / gift are chosen on the server when the adventure starts; the texts live in the client.
create table public.pet_adventures (
  id uuid primary key default gen_random_uuid(),
  pet_id uuid not null references public.pets(id) on delete cascade,
  user_id uuid not null,
  day date not null,
  started_at timestamptz not null default now(),
  returns_at timestamptz not null,
  story_idx int not null,
  gift text not null check (gift in ('souvenir','heart','tomato')),
  souvenir_idx int not null,
  collected_at timestamptz,
  unique (pet_id, day)
);
alter table public.pet_adventures enable row level security;
create policy "read own adventures" on public.pet_adventures for select using (user_id = auth.uid());
revoke all on public.pet_adventures from anon, authenticated;
grant select on public.pet_adventures to authenticated;

alter table public.pet_events drop constraint pet_events_kind_check;
alter table public.pet_events add constraint pet_events_kind_check check (kind in
 ('created','retired','browser','email','death','rescue','valid_checkin','renamed','task','meditation_started','meditation_resumed',
  'repair_used','repair_earned','vacation_started','vacation_ended','adventure_started','adventure_collected'));

create or replace function private.collect_adv(a public.pet_adventures) returns void
language plpgsql security definer set search_path = '' as $$
begin
  update public.pet_adventures set collected_at = now() where id = a.id;
  update public.pets set
    happiness = case when a.gift = 'heart' then least(7, happiness + 1) else happiness end,
    fruits    = case when a.gift = 'tomato' then fruits + 1 else fruits end
  where id = a.pet_id and alive;
  insert into public.pet_events(pet_id, user_id, day, kind, detail)
  values (a.pet_id, a.user_id, private.today_for(a.user_id), 'adventure_collected', jsonb_build_object('gift', a.gift));
end $$;

create or replace function public.collect_adventure() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid(); a public.pet_adventures;
begin
  if uid is null then raise exception 'Not signed in'; end if;
  select * into a from public.pet_adventures
   where user_id = uid and collected_at is null and returns_at <= now()
   order by started_at desc limit 1 for update;
  if a.id is null then raise exception 'Your pet is still out exploring'; end if;
  perform private.collect_adv(a);
  return private.state(uid) || jsonb_build_object('collected',
    jsonb_build_object('story', a.story_idx, 'gift', a.gift, 'souvenir', a.souvenir_idx));
end $$;
revoke all on function public.collect_adventure() from public, anon;
grant execute on function public.collect_adventure() to authenticated;

-- state(): expose the current adventure
create or replace function private.state(p_uid uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  t date := private.today_for(p_uid);
  prof public.profiles; p public.pets; c public.daily_checkins; adv public.pet_adventures;
  nlog integer; left_s integer; adv_json jsonb; rdy boolean;
begin
  select * into prof from public.profiles where id = p_uid;
  select * into p from public.pets where user_id = p_uid and retired_at is null;
  if p.id is not null then
    p := private.sync_pet(p, t);
    select * into c from public.daily_checkins where pet_id = p.id and day = t;
    select * into adv from public.pet_adventures where pet_id = p.id and collected_at is null order by started_at desc limit 1;
  end if;
  select count(*) into nlog from public.logins where user_id = p_uid and day = t;
  if c.pet_id is not null and not c.meditate and c.meditation_started_at is not null and c.meditation_seen_at is not null
     and now() - c.meditation_seen_at <= interval '15 minutes' then
    left_s := greatest(0, 600 - extract(epoch from (c.meditation_seen_at - c.meditation_started_at))::int);
  end if;
  if adv.id is not null then
    rdy := adv.returns_at <= now();
    adv_json := jsonb_build_object('returns_at', adv.returns_at, 'seconds_left', greatest(0, ceil(extract(epoch from (adv.returns_at - now())))::int),
      'ready', rdy, 'story', case when rdy then adv.story_idx end, 'gift', case when rdy then adv.gift end, 'souvenir', case when rdy then adv.souvenir_idx end);
  end if;
  return jsonb_build_object(
    'today', t, 'timezone', prof.timezone, 'logins_today', nlog,
    'pet', case when p.id is null then null else
      to_jsonb(p) || jsonb_build_object(
        'absent_days', greatest(0, t - p.last_checkin_day - 1),
        'streak_now', case when p.vacation_since is not null then p.streak
                           when p.last_valid_day is not null and t - p.last_valid_day - 1 <= p.repairs then p.streak else 0 end,
        'vacation_days_left', case when p.vacation_since is not null then greatest(0, 21 - (t - p.vacation_since)) end,
        'needs_new_pet', (not p.alive and p.rescues >= 5)) end,
    'adventure', adv_json,
    'tasks', jsonb_build_object(
      'feed', coalesce(c.feed, false), 'water', coalesce(c.water, false),
      'play', coalesce(c.play, false), 'meditate', coalesce(c.meditate, false),
      'rewarded', coalesce(c.rewarded, false), 'meditation_started_at', c.meditation_started_at,
      'meditation_resume_left', left_s)
  );
end $$;

-- complete_task(): start an adventure when the day counts
create or replace function public.complete_task(p_task text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := auth.uid(); t date; p public.pets; c public.daily_checkins; old public.pet_adventures;
  is_valid boolean := false; is_gift boolean := false; was_done boolean;
  missed int := 0; used int := 0; earned boolean := false; new_prog int; new_rep int; r double precision;
begin
  if uid is null then raise exception 'Not signed in'; end if;
  if p_task not in ('feed','water','play','meditate') then raise exception 'Unknown task'; end if;
  t := private.today_for(uid);
  select * into p from public.pets where user_id = uid and retired_at is null for update;
  if p.id is null then raise exception 'No pet'; end if;
  p := private.sync_pet(p, t);
  if not p.alive then raise exception 'Your pet went off to play. Send it a letter first.'; end if;

  insert into public.daily_checkins(pet_id, user_id, day) values (p.id, uid, t) on conflict (pet_id, day) do nothing;
  select * into c from public.daily_checkins where pet_id = p.id and day = t for update;

  if p_task = 'meditate' and (c.meditation_started_at is null or now() - c.meditation_started_at < interval '9 minutes 50 seconds') then
    raise exception 'Meditation needs the full 10 minutes';
  end if;
  was_done := case p_task when 'feed' then c.feed when 'water' then c.water when 'play' then c.play else c.meditate end;

  update public.daily_checkins
     set feed = feed or p_task = 'feed', water = water or p_task = 'water',
         play = play or p_task = 'play', meditate = meditate or p_task = 'meditate',
         updated_at = now()
   where pet_id = p.id and day = t
  returning * into c;

  if not was_done then
    insert into public.pet_events(pet_id, user_id, day, kind, detail) values (p.id, uid, t, 'task', jsonb_build_object('task', p_task));
  end if;

  if c.feed and c.water and c.play and c.meditate and not c.rewarded
     and (p.last_reward_day is null or t > p.last_reward_day) then
    if p.last_valid_day is not null then missed := t - p.last_valid_day - 1; end if;
    if missed >= 1 and missed <= p.repairs then used := missed; end if;
    new_rep := p.repairs - used;
    new_prog := p.repair_progress + 1;
    if new_prog >= 3 then
      new_prog := 0;
      if new_rep < 2 then new_rep := new_rep + 1; earned := true; end if;
    end if;
    update public.pets
       set streak = case when last_valid_day = t - 1 or used > 0 then streak + 1 else 1 end,
           repairs = new_rep, repair_progress = new_prog,
           last_valid_day = t, last_reward_day = t,
           happiness = least(7, happiness + 1), fruits = fruits + 1,
           last_checkin_day = t, applied_absence = 0, notified = '{}'
     where id = p.id
    returning * into p;
    update public.daily_checkins set rewarded = true, completed_at = now() where pet_id = p.id and day = t;
    insert into public.pet_events(pet_id, user_id, day, kind, detail)
         values (p.id, uid, t, 'valid_checkin', jsonb_build_object('streak', p.streak, 'fruits', p.fruits));
    if used > 0 then
      insert into public.pet_events(pet_id, user_id, day, kind, detail) values (p.id, uid, t, 'repair_used', jsonb_build_object('days', used));
    end if;
    if earned then
      insert into public.pet_events(pet_id, user_id, day, kind, detail) values (p.id, uid, t, 'repair_earned', jsonb_build_object('repairs', p.repairs));
    end if;
    is_valid := true;
    is_gift := (p.streak % 7 = 0);

    -- send the pet on a 6-hour adventure; an unclaimed older one is claimed automatically
    for old in select * from public.pet_adventures where pet_id = p.id and collected_at is null loop
      perform private.collect_adv(old);
    end loop;
    r := random();
    insert into public.pet_adventures(pet_id, user_id, day, returns_at, story_idx, gift, souvenir_idx)
    values (p.id, uid, t, now() + interval '6 hours', floor(random() * 10)::int,
            case when r < 0.5 then 'souvenir' when r < 0.85 then 'heart' else 'tomato' end, floor(random() * 8)::int)
    on conflict (pet_id, day) do nothing;
    insert into public.pet_events(pet_id, user_id, day, kind, detail) values (p.id, uid, t, 'adventure_started', '{}'::jsonb);
  end if;

  return private.state(uid) || jsonb_build_object('valid', is_valid, 'gift', is_gift, 'repaired', used, 'repair_earned', earned);
end $$;
