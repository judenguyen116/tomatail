create schema if not exists private;
revoke all on schema private from public, anon, authenticated;

-- ---------- tables ----------
create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text,
  timezone text not null default 'Asia/Ho_Chi_Minh',
  created_at timestamptz not null default now()
);

create table public.pets (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  species text not null check (species in ('chicken','parrot','pig','hamster','monkey','turtle','snake','fish')),
  alive boolean not null default true,
  happiness smallint not null default 7 check (happiness between 0 and 7),
  fruits integer not null default 0 check (fruits >= 0),
  rescues smallint not null default 0 check (rescues between 0 and 5),
  streak integer not null default 0 check (streak >= 0),
  last_valid_day date,
  last_reward_day date,
  last_checkin_day date not null,
  applied_absence integer not null default 0,
  notified text[] not null default '{}',
  died_on date,
  created_at timestamptz not null default now(),
  retired_at timestamptz
);
create unique index pets_one_active_per_user on public.pets(user_id) where retired_at is null;
create index pets_user_idx on public.pets(user_id);

create table public.daily_checkins (
  pet_id uuid not null references public.pets(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  day date not null,
  feed boolean not null default false,
  water boolean not null default false,
  play boolean not null default false,
  meditate boolean not null default false,
  meditation_started_at timestamptz,
  rewarded boolean not null default false,
  completed_at timestamptz,
  updated_at timestamptz not null default now(),
  primary key (pet_id, day)
);
create index daily_checkins_user_idx on public.daily_checkins(user_id, day);

create table public.logins (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  day date not null,
  at timestamptz not null default now()
);
create index logins_user_day_idx on public.logins(user_id, day);

create table public.pet_events (
  id bigint generated always as identity primary key,
  pet_id uuid not null references public.pets(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  day date not null,
  kind text not null check (kind in ('created','retired','browser','email','death','rescue','valid_checkin')),
  detail jsonb,
  at timestamptz not null default now()
);
create index pet_events_user_idx on public.pet_events(user_id, at desc);
create index pet_events_pet_idx on public.pet_events(pet_id);

-- ---------- RLS: users read only their own rows; all writes go through RPC functions ----------
alter table public.profiles enable row level security;
alter table public.pets enable row level security;
alter table public.daily_checkins enable row level security;
alter table public.logins enable row level security;
alter table public.pet_events enable row level security;

create policy "read own profile" on public.profiles for select to authenticated using ((select auth.uid()) = id);
create policy "read own pets" on public.pets for select to authenticated using ((select auth.uid()) = user_id);
create policy "read own checkins" on public.daily_checkins for select to authenticated using ((select auth.uid()) = user_id);
create policy "read own logins" on public.logins for select to authenticated using ((select auth.uid()) = user_id);
create policy "read own events" on public.pet_events for select to authenticated using ((select auth.uid()) = user_id);

revoke insert, update, delete, truncate on public.profiles, public.pets, public.daily_checkins, public.logins, public.pet_events from anon, authenticated;
revoke all on public.profiles, public.pets, public.daily_checkins, public.logins, public.pet_events from anon;

-- ---------- new user -> profile ----------
create or replace function private.handle_new_user() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.profiles(id, email) values (new.id, new.email) on conflict (id) do nothing;
  return new;
end $$;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function private.handle_new_user();

-- ---------- game rules (server side) ----------
create or replace function private.today_for(p_uid uuid) returns date
language sql stable security definer set search_path = '' as $$
  select (now() at time zone coalesce((select timezone from public.profiles where id = p_uid), 'UTC'))::date
$$;

-- applies absence: -1 happiness and -1 tomato per missed day, reminders at 1 and 6 days, death at 7
create or replace function private.sync_pet(p_pet public.pets, p_today date) returns public.pets
language plpgsql security definer set search_path = '' as $$
declare
  r public.pets := p_pet;
  n integer;
  d integer;
begin
  if r.id is null or not r.alive or r.retired_at is not null then return r; end if;
  n := greatest(0, p_today - r.last_checkin_day - 1);
  if n > r.applied_absence then
    d := n - r.applied_absence;
    r.happiness := greatest(0, r.happiness - d);
    r.fruits := greatest(0, r.fruits - d);
    r.applied_absence := n;
  end if;
  if n >= 1 and not ('browser' = any(r.notified)) then
    r.notified := array_append(r.notified, 'browser');
    insert into public.pet_events(pet_id, user_id, day, kind) values (r.id, r.user_id, p_today, 'browser');
  end if;
  if n >= 6 and not ('email' = any(r.notified)) then
    r.notified := array_append(r.notified, 'email');
    insert into public.pet_events(pet_id, user_id, day, kind) values (r.id, r.user_id, p_today, 'email');
  end if;
  if n >= 7 then
    r.alive := false; r.died_on := p_today; r.happiness := 0; r.fruits := 0;
    r.notified := array_append(r.notified, 'death');
    insert into public.pet_events(pet_id, user_id, day, kind) values (r.id, r.user_id, p_today, 'death');
  end if;
  update public.pets
     set happiness = r.happiness, fruits = r.fruits, applied_absence = r.applied_absence,
         notified = r.notified, alive = r.alive, died_on = r.died_on
   where id = r.id;
  return r;
end $$;

create or replace function private.state(p_uid uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  t date := private.today_for(p_uid);
  prof public.profiles;
  p public.pets;
  c public.daily_checkins;
  nlog integer;
begin
  select * into prof from public.profiles where id = p_uid;
  select * into p from public.pets where user_id = p_uid and retired_at is null;
  if p.id is not null then
    p := private.sync_pet(p, t);
    select * into c from public.daily_checkins where pet_id = p.id and day = t;
  end if;
  select count(*) into nlog from public.logins where user_id = p_uid and day = t;
  return jsonb_build_object(
    'today', t,
    'timezone', prof.timezone,
    'logins_today', nlog,
    'pet', case when p.id is null then null else
      to_jsonb(p) || jsonb_build_object(
        'absent_days', greatest(0, t - p.last_checkin_day - 1),
        'streak_now', case when p.last_valid_day is not null and t - p.last_valid_day <= 1 then p.streak else 0 end,
        'needs_new_pet', (not p.alive and p.rescues >= 5)) end,
    'tasks', jsonb_build_object(
      'feed', coalesce(c.feed, false), 'water', coalesce(c.water, false),
      'play', coalesce(c.play, false), 'meditate', coalesce(c.meditate, false),
      'rewarded', coalesce(c.rewarded, false), 'meditation_started_at', c.meditation_started_at)
  );
end $$;

create or replace function private.sync_all() returns integer
language plpgsql security definer set search_path = '' as $$
declare p public.pets; k integer := 0;
begin
  for p in select * from public.pets where alive and retired_at is null loop
    perform private.sync_pet(p, private.today_for(p.user_id));
    k := k + 1;
  end loop;
  return k;
end $$;

revoke all on all functions in schema private from public, anon, authenticated;

-- ---------- public RPCs (signed-in users only) ----------
create or replace function public.get_state() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid();
begin
  if uid is null then raise exception 'Not signed in'; end if;
  return private.state(uid);
end $$;

-- call once per visit: counts the login and voids an unfinished day (leaving early does not count)
create or replace function public.record_login() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid(); t date;
begin
  if uid is null then raise exception 'Not signed in'; end if;
  t := private.today_for(uid);
  insert into public.logins(user_id, day) values (uid, t);
  update public.daily_checkins
     set feed = false, water = false, play = false, meditate = false,
         meditation_started_at = null, updated_at = now()
   where user_id = uid and day = t and not rewarded;
  return private.state(uid);
end $$;

create or replace function public.adopt_pet(p_species text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid(); t date; cur public.pets; np public.pets;
begin
  if uid is null then raise exception 'Not signed in'; end if;
  t := private.today_for(uid);
  select * into cur from public.pets where user_id = uid and retired_at is null for update;
  if cur.id is not null then
    if cur.alive then raise exception 'You already have a pet'; end if;
    if cur.rescues < 5 then raise exception 'Your pet can still be rescued with a letter'; end if;
    update public.pets set retired_at = now() where id = cur.id;
    insert into public.pet_events(pet_id, user_id, day, kind) values (cur.id, uid, t, 'retired');
  end if;
  insert into public.pets(user_id, species, last_checkin_day) values (uid, p_species, t) returning * into np;
  insert into public.pet_events(pet_id, user_id, day, kind, detail) values (np.id, uid, t, 'created', jsonb_build_object('species', p_species));
  return private.state(uid);
end $$;

-- prototype tool: give up the current pet so a new one can be adopted
create or replace function public.retire_pet() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid(); t date; cur public.pets;
begin
  if uid is null then raise exception 'Not signed in'; end if;
  t := private.today_for(uid);
  select * into cur from public.pets where user_id = uid and retired_at is null for update;
  if cur.id is not null then
    update public.pets set retired_at = now() where id = cur.id;
    insert into public.pet_events(pet_id, user_id, day, kind, detail) values (cur.id, uid, t, 'retired', '{"by":"user"}');
  end if;
  return private.state(uid);
end $$;

create or replace function public.start_meditation() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid(); t date; p public.pets;
begin
  if uid is null then raise exception 'Not signed in'; end if;
  t := private.today_for(uid);
  select * into p from public.pets where user_id = uid and retired_at is null;
  if p.id is null or not p.alive then raise exception 'No living pet'; end if;
  insert into public.daily_checkins(pet_id, user_id, day, meditation_started_at)
       values (p.id, uid, t, now())
  on conflict (pet_id, day) do update set meditation_started_at = now(), updated_at = now();
  return private.state(uid);
end $$;

create or replace function public.complete_task(p_task text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := auth.uid(); t date; p public.pets; c public.daily_checkins;
  is_valid boolean := false; is_gift boolean := false;
begin
  if uid is null then raise exception 'Not signed in'; end if;
  if p_task not in ('feed','water','play','meditate') then raise exception 'Unknown task'; end if;
  t := private.today_for(uid);
  select * into p from public.pets where user_id = uid and retired_at is null for update;
  if p.id is null then raise exception 'No pet'; end if;
  p := private.sync_pet(p, t);
  if not p.alive then raise exception 'Your pet is gone. Send it a letter first.'; end if;

  insert into public.daily_checkins(pet_id, user_id, day) values (p.id, uid, t) on conflict (pet_id, day) do nothing;
  select * into c from public.daily_checkins where pet_id = p.id and day = t for update;

  if p_task = 'meditate' and (c.meditation_started_at is null or now() - c.meditation_started_at < interval '9 minutes 50 seconds') then
    raise exception 'Meditation needs the full 10 minutes';
  end if;

  update public.daily_checkins
     set feed = feed or p_task = 'feed', water = water or p_task = 'water',
         play = play or p_task = 'play', meditate = meditate or p_task = 'meditate',
         updated_at = now()
   where pet_id = p.id and day = t
  returning * into c;

  -- one tomato and one happiness point per day, no matter how many logins
  if c.feed and c.water and c.play and c.meditate and not c.rewarded
     and (p.last_reward_day is null or t > p.last_reward_day) then
    update public.pets
       set streak = case when last_valid_day = t - 1 then streak + 1 else 1 end,
           last_valid_day = t, last_reward_day = t,
           happiness = least(7, happiness + 1), fruits = fruits + 1,
           last_checkin_day = t, applied_absence = 0, notified = '{}'
     where id = p.id
    returning * into p;
    update public.daily_checkins set rewarded = true, completed_at = now() where pet_id = p.id and day = t;
    insert into public.pet_events(pet_id, user_id, day, kind, detail)
         values (p.id, uid, t, 'valid_checkin', jsonb_build_object('streak', p.streak, 'fruits', p.fruits));
    is_valid := true;
    is_gift := (p.streak % 7 = 0);
  end if;

  return private.state(uid) || jsonb_build_object('valid', is_valid, 'gift', is_gift);
end $$;

create or replace function public.rescue_pet(p_letter text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid(); t date; p public.pets;
begin
  if uid is null then raise exception 'Not signed in'; end if;
  if p_letter is null or length(trim(p_letter)) = 0 or length(p_letter) > 280 then raise exception 'Write a one-line letter (up to 280 characters)'; end if;
  t := private.today_for(uid);
  select * into p from public.pets where user_id = uid and retired_at is null for update;
  if p.id is null then raise exception 'No pet'; end if;
  if p.alive then raise exception 'Your pet is alive'; end if;
  if p.rescues >= 5 then raise exception 'No rescues left for this pet'; end if;
  update public.pets
     set alive = true, happiness = 7, fruits = 0, rescues = rescues + 1,
         streak = 0, last_valid_day = null, last_checkin_day = t,
         applied_absence = 0, notified = '{}', died_on = null
   where id = p.id;
  insert into public.pet_events(pet_id, user_id, day, kind, detail) values (p.id, uid, t, 'rescue', jsonb_build_object('letter', p_letter));
  return private.state(uid);
end $$;

create or replace function public.set_timezone(p_tz text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid();
begin
  if uid is null then raise exception 'Not signed in'; end if;
  if not exists (select 1 from pg_catalog.pg_timezone_names where name = p_tz) then raise exception 'Unknown time zone'; end if;
  update public.profiles set timezone = p_tz where id = uid;
  return private.state(uid);
end $$;

revoke all on function public.get_state(), public.record_login(), public.adopt_pet(text), public.retire_pet(),
  public.start_meditation(), public.complete_task(text), public.rescue_pet(text), public.set_timezone(text) from public, anon;
grant execute on function public.get_state(), public.record_login(), public.adopt_pet(text), public.retire_pet(),
  public.start_meditation(), public.complete_task(text), public.rescue_pet(text), public.set_timezone(text) to authenticated;
