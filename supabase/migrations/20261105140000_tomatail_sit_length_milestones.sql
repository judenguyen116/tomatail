-- Sit length (3, 5 or 10 minutes), a bonus tomato for a full 10-minute sit, and first-week milestones.
alter table public.daily_checkins add column meditation_minutes int check (meditation_minutes in (3,5,10));
alter table public.pets add column valid_days int not null default 0;
update public.pets p set valid_days = (select count(*) from public.pet_events e where e.pet_id = p.id and e.kind = 'valid_checkin');

alter table public.pet_events drop constraint pet_events_kind_check;
alter table public.pet_events add constraint pet_events_kind_check check (kind in
 ('created','retired','browser','email','death','rescue','valid_checkin','renamed','task','meditation_started','meditation_resumed',
  'repair_used','repair_earned','vacation_started','vacation_ended','adventure_started','adventure_collected','item_bought','milestone'));

drop function public.start_meditation();
create or replace function public.start_meditation(p_minutes int default 10) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := auth.uid(); t date; p public.pets; c public.daily_checkins;
  accum numeric := 0; resumed boolean := false; mins int;
begin
  if uid is null then raise exception 'Not signed in'; end if;
  if p_minutes not in (3,5,10) then raise exception 'Pick 3, 5 or 10 minutes'; end if;
  t := private.today_for(uid);
  select * into p from public.pets where user_id = uid and retired_at is null;
  if p.id is null or not p.alive then raise exception 'No living pet'; end if;
  select * into c from public.daily_checkins where pet_id = p.id and day = t for update;
  mins := p_minutes;
  if c.pet_id is not null and not c.meditate and c.meditation_started_at is not null and c.meditation_seen_at is not null
     and now() - c.meditation_seen_at <= interval '15 minutes' then
    mins := coalesce(c.meditation_minutes, 10);
    accum := least(mins * 60, greatest(0, extract(epoch from (c.meditation_seen_at - c.meditation_started_at))));
    update public.daily_checkins
       set meditation_started_at = now() - make_interval(secs => accum), meditation_seen_at = now(), updated_at = now()
     where pet_id = p.id and day = t;
    insert into public.pet_events(pet_id, user_id, day, kind, detail)
         values (p.id, uid, t, 'meditation_resumed', jsonb_build_object('elapsed', round(accum), 'minutes', mins));
    resumed := true;
  else
    insert into public.daily_checkins(pet_id, user_id, day, meditation_started_at, meditation_seen_at, meditation_minutes)
         values (p.id, uid, t, now(), now(), mins)
    on conflict (pet_id, day) do update set meditation_started_at = now(), meditation_seen_at = now(), meditation_minutes = mins, updated_at = now();
    insert into public.pet_events(pet_id, user_id, day, kind, detail) values (p.id, uid, t, 'meditation_started', jsonb_build_object('minutes', mins));
  end if;
  return private.state(uid) || jsonb_build_object('resumed', resumed, 'elapsed', round(accum), 'minutes', mins);
end $$;
revoke all on function public.start_meditation(int) from public, anon;
grant execute on function public.start_meditation(int) to authenticated;

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
    left_s := greatest(0, coalesce(c.meditation_minutes, 10) * 60 - extract(epoch from (c.meditation_seen_at - c.meditation_started_at))::int);
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
      'meditation_resume_left', left_s, 'meditation_minutes', c.meditation_minutes)
  );
end $$;

create or replace function public.complete_task(p_task text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := auth.uid(); t date; p public.pets; c public.daily_checkins; old public.pet_adventures;
  is_valid boolean := false; is_gift boolean := false; was_done boolean;
  missed int := 0; used int := 0; earned boolean := false; new_prog int; new_rep int; r double precision;
  need_secs int; bonus boolean := false; ms jsonb := null; extra int := 0; n int;
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

  need_secs := coalesce(c.meditation_minutes, 10) * 60 - 10;
  if p_task = 'meditate' and (c.meditation_started_at is null or now() - c.meditation_started_at < make_interval(secs => need_secs)) then
    raise exception 'Keep sitting until the timer ends';
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
    bonus := coalesce(c.meditation_minutes, 10) = 10;
    update public.pets
       set streak = case when last_valid_day = t - 1 or used > 0 then streak + 1 else 1 end,
           repairs = new_rep, repair_progress = new_prog,
           last_valid_day = t, last_reward_day = t,
           happiness = least(7, happiness + 1), fruits = fruits + 1 + (case when bonus then 1 else 0 end),
           valid_days = valid_days + 1,
           last_checkin_day = t, applied_absence = 0, notified = '{}'
     where id = p.id
    returning * into p;
    update public.daily_checkins set rewarded = true, completed_at = now() where pet_id = p.id and day = t;
    insert into public.pet_events(pet_id, user_id, day, kind, detail)
         values (p.id, uid, t, 'valid_checkin', jsonb_build_object('streak', p.streak, 'fruits', p.fruits, 'bonus', bonus));
    if used > 0 then
      insert into public.pet_events(pet_id, user_id, day, kind, detail) values (p.id, uid, t, 'repair_used', jsonb_build_object('days', used));
    end if;
    if earned then
      insert into public.pet_events(pet_id, user_id, day, kind, detail) values (p.id, uid, t, 'repair_earned', jsonb_build_object('repairs', p.repairs));
    end if;
    is_valid := true;
    is_gift := (p.streak % 7 = 0);

    -- first-week milestones, counted in days completed (not streak): day 1 a cap, day 3 three tomatoes, day 7 a cape
    if p.valid_days = 1 then
      if 'hat_cap' = any(p.owned) then extra := 3; ms := jsonb_build_object('day', 1, 'tomatoes', 3);
      else update public.pets set owned = array_append(owned, 'hat_cap'), hat = coalesce(hat, 'hat_cap') where id = p.id;
           ms := jsonb_build_object('day', 1, 'item', 'hat_cap'); end if;
    elsif p.valid_days = 3 then
      extra := 3; ms := jsonb_build_object('day', 3, 'tomatoes', 3);
    elsif p.valid_days = 7 then
      if 'fit_cape' = any(p.owned) then extra := 8; ms := jsonb_build_object('day', 7, 'tomatoes', 8);
      else update public.pets set owned = array_append(owned, 'fit_cape'), outfit = coalesce(outfit, 'fit_cape') where id = p.id;
           ms := jsonb_build_object('day', 7, 'item', 'fit_cape'); end if;
    end if;
    if ms is not null then
      if extra > 0 then update public.pets set fruits = fruits + extra where id = p.id; end if;
      insert into public.pet_events(pet_id, user_id, day, kind, detail) values (p.id, uid, t, 'milestone', ms);
    end if;

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

  return private.state(uid) || jsonb_build_object('valid', is_valid, 'gift', is_gift, 'repaired', used, 'repair_earned', earned,
                                                  'bonus', bonus and is_valid, 'milestone', ms);
end $$;
