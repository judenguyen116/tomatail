-- Time zone hopping gave a second tomato in the same real day; login spam could flood the logins table.
alter table public.profiles add column if not exists timezone_changed_at timestamptz;

-- set_timezone: first set is free, then once every 7 days; if today's tomato was already earned,
-- the new "today" counts as already rewarded.
create or replace function public.set_timezone(p_tz text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid(); prof public.profiles; old_t date; new_t date;
begin
  if uid is null then raise exception 'Not signed in'; end if;
  if not exists (select 1 from pg_catalog.pg_timezone_names where name = p_tz) then raise exception 'Unknown time zone'; end if;
  select * into prof from public.profiles where id = uid for update;
  if prof.timezone is distinct from p_tz then
    if prof.timezone_changed_at is not null and now() - prof.timezone_changed_at < interval '7 days' then
      raise exception 'You can change your time zone once every 7 days';
    end if;
    old_t := private.today_for(uid);
    update public.profiles set timezone = p_tz, timezone_changed_at = now() where id = uid;
    new_t := private.today_for(uid);
    update public.pets set last_reward_day = greatest(last_reward_day, new_t)
     where user_id = uid and retired_at is null and last_reward_day >= old_t;
  end if;
  return private.state(uid);
end $$;

-- record_login: at most one counted login per minute per user.
create or replace function public.record_login() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid(); t date;
begin
  if uid is null then raise exception 'Not signed in'; end if;
  t := private.today_for(uid);
  if not exists (select 1 from public.logins where user_id = uid and at > now() - interval '1 minute') then
    insert into public.logins(user_id, day) values (uid, t);
  end if;
  update public.daily_checkins
     set feed = false, water = false, play = false, meditate = false,
         meditation_started_at = null, updated_at = now()
   where user_id = uid and day = t and not rewarded;
  return private.state(uid);
end $$;

revoke all on function public.set_timezone(text), public.record_login() from public, anon;
grant execute on function public.set_timezone(text), public.record_login() to authenticated;

-- sync_pet: reads no longer write the pet row unless something changed (less locking under load).
create or replace function private.sync_pet(p_pet public.pets, p_today date) returns public.pets
language plpgsql security definer set search_path = '' as $$
declare r public.pets := p_pet; n integer; d integer; changed boolean := false;
begin
  if r.id is null or not r.alive or r.retired_at is not null then return r; end if;
  n := greatest(0, p_today - r.last_checkin_day - 1);
  if n > r.applied_absence then
    d := n - r.applied_absence;
    r.happiness := greatest(0, r.happiness - d); r.fruits := greatest(0, r.fruits - d); r.applied_absence := n; changed := true;
  end if;
  if n >= 1 and not ('browser' = any(r.notified)) then
    r.notified := array_append(r.notified, 'browser');
    insert into public.pet_events(pet_id, user_id, day, kind) values (r.id, r.user_id, p_today, 'browser'); changed := true;
  end if;
  if n >= 6 and not ('email' = any(r.notified)) then
    r.notified := array_append(r.notified, 'email');
    insert into public.pet_events(pet_id, user_id, day, kind) values (r.id, r.user_id, p_today, 'email'); changed := true;
  end if;
  if n >= 7 then
    r.alive := false; r.died_on := p_today; r.happiness := 0; r.fruits := 0;
    r.notified := array_append(r.notified, 'death');
    insert into public.pet_events(pet_id, user_id, day, kind) values (r.id, r.user_id, p_today, 'death'); changed := true;
  end if;
  if changed then
    update public.pets set happiness = r.happiness, fruits = r.fruits, applied_absence = r.applied_absence,
           notified = r.notified, alive = r.alive, died_on = r.died_on where id = r.id;
  end if;
  return r;
end $$;
revoke all on function private.sync_pet(public.pets, date) from public, anon, authenticated;
