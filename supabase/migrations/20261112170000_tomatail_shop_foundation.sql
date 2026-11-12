-- Paid shop foundation (step 1). Nothing changes for players while payments_mode = 'off'.
-- payments_mode: 'off' (default) | 'sandbox' (only profiles.is_test users see the paid shop) | 'live'.

create table if not exists private.config (key text primary key, value text not null);
alter table private.config enable row level security;
insert into private.config values ('payments_mode', 'off') on conflict do nothing;

create or replace function private.paid_visible(p_uid uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select case (select value from private.config where key = 'payments_mode')
    when 'live' then true
    when 'sandbox' then coalesce((select is_test from public.profiles where id = p_uid), false)
    else false end
$$;

-- Everything sold for real money. Prices are in US cents. grants = item or species ids unlocked.
create table if not exists public.catalog (
  sku text primary key,
  kind text not null check (kind in ('item','species','bundle')),
  name text not null,
  price_cents int not null check (price_cents > 0),
  grants text[] not null,
  rule text,                       -- 'one_hat_one_outfit': buyer picks 1 hat + 1 outfit from grants
  sale_start date, sale_end date,  -- inclusive, null = always on sale
  sort int not null default 0,
  active boolean not null default true
);
alter table public.catalog enable row level security;
drop policy if exists catalog_read on public.catalog;
create policy catalog_read on public.catalog for select using (true);

-- What an account owns forever (survives resetting or retiring a pet).
create table if not exists public.entitlements (
  user_id uuid not null references auth.users(id) on delete cascade,
  item text not null,
  sku text, order_id uuid,
  source text not null check (source in ('paypal','grandfather','gift')),
  created_at timestamptz not null default now(),
  primary key (user_id, item)
);
alter table public.entitlements enable row level security;
drop policy if exists entitlements_read_own on public.entitlements;
create policy entitlements_read_own on public.entitlements for select using (auth.uid() = user_id);

create table if not exists public.orders (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  sku text not null references public.catalog(sku),
  picks text[],
  paypal_order_id text unique,
  amount_cents int not null, currency text not null default 'USD',
  status text not null default 'created' check (status in ('created','completed','failed','refunded')),
  created_at timestamptz not null default now(), completed_at timestamptz
);
alter table public.orders enable row level security;
drop policy if exists orders_read_own on public.orders;
create policy orders_read_own on public.orders for select using (auth.uid() = user_id);

revoke all on public.catalog, public.entitlements, public.orders from anon, authenticated;
grant select on public.catalog to anon, authenticated;
grant select on public.entitlements, public.orders to authenticated;

insert into public.catalog (sku, kind, name, price_cents, grants, rule, sale_start, sale_end, sort) values
 ('item_hat_party','item','Party hat',50,'{hat_party}',null,null,null,10),
 ('item_hat_wizard','item','Wizard hat',50,'{hat_wizard}',null,null,null,11),
 ('item_hat_crown','item','Tiny crown',50,'{hat_crown}',null,null,null,12),
 ('item_fit_hoodie','item','Purple hoodie',50,'{fit_hoodie}',null,null,null,13),
 ('item_fit_cape','item','Hero cape',50,'{fit_cape}',null,null,null,14),
 ('item_fit_kimono','item','Kimono',50,'{fit_kimono}',null,null,null,15),
 ('bundle_premium','bundle','Premium set (6 items)',200,'{hat_party,hat_wizard,hat_crown,fit_hoodie,fit_cape,fit_kimono}',null,null,null,20),
 ('pet_monkey','species','Golden monkey',150,'{monkey}',null,null,null,30),
 ('xmas_hat_santa','item','Santa hat',50,'{hat_santa}',null,'2026-11-15','2026-12-31',40),
 ('xmas_hat_elf','item','Elf hat',50,'{hat_elf}',null,'2026-11-15','2026-12-31',41),
 ('xmas_hat_holly','item','Holly crown',50,'{hat_holly}',null,'2026-11-15','2026-12-31',42),
 ('xmas_fit_candy','item','Candy scarf',50,'{fit_candy}',null,'2026-11-15','2026-12-31',43),
 ('xmas_fit_xmas','item','Xmas sweater',50,'{fit_xmas}',null,'2026-11-15','2026-12-31',44),
 ('xmas_fit_bell','item','Bell collar',50,'{fit_bell}',null,'2026-11-15','2026-12-31',45),
 ('xmas_pair','bundle','Christmas pair (1 hat + 1 outfit)',80,'{hat_santa,hat_elf,hat_holly,fit_candy,fit_xmas,fit_bell}','one_hat_one_outfit','2026-11-15','2026-12-31',46),
 ('xmas_set','bundle','Christmas set (6 items)',200,'{hat_santa,hat_elf,hat_holly,fit_candy,fit_xmas,fit_bell}',null,'2026-11-15','2026-12-31',47),
 ('pet_reindeer','species','Reindeer',200,'{reindeer}',null,'2026-11-15','2026-12-31',50),
 ('pet_reindeer_set','bundle','Reindeer + Christmas set',350,'{reindeer,hat_santa,hat_elf,hat_holly,fit_candy,fit_xmas,fit_bell}',null,'2026-11-15','2026-12-31',51)
on conflict (sku) do nothing;

-- Species list now includes the reindeer.
alter table public.pets drop constraint if exists pets_species_check;
alter table public.pets add constraint pets_species_check
  check (species = any (array['chicken','parrot','pig','hamster','monkey','turtle','snake','fish','reindeer']));

-- Give people what they already have before an item or pet turns into a paid one. Safe to re-run.
create or replace function private.grandfather() returns int
language plpgsql security definer set search_path = '' as $$
declare n int;
begin
  insert into public.entitlements (user_id, item, source)
  select distinct p.user_id, o, 'grandfather'
    from public.pets p, unnest(p.owned) o
   where o in ('hat_party','hat_wizard','hat_crown','fit_hoodie','fit_cape','fit_kimono')
  on conflict do nothing;
  get diagnostics n = row_count;
  insert into public.entitlements (user_id, item, source)
  select distinct user_id, 'monkey', 'grandfather' from public.pets where species = 'monkey'
  on conflict do nothing;
  return n;
end $$;
revoke all on function private.grandfather() from public, anon, authenticated;
select private.grandfather();

-- state(): owned now includes account-level entitlements; also reports entitlements and whether the paid shop is visible.
create or replace function private.state(p_uid uuid)
returns jsonb language plpgsql security definer set search_path = '' as $f$
declare
  t date := private.today_for(p_uid);
  prof public.profiles; p public.pets; c public.daily_checkins; adv public.pet_adventures;
  nlog integer; left_s integer; adv_json jsonb; rdy boolean; ent text[];
begin
  select * into prof from public.profiles where id = p_uid;
  ent := coalesce(array(select e.item from public.entitlements e where e.user_id = p_uid), '{}');
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
    'entitlements', to_jsonb(ent), 'paid_shop', private.paid_visible(p_uid),
    'pet', case when p.id is null then null else
      to_jsonb(p) || jsonb_build_object(
        'owned', to_jsonb(array(select distinct x from unnest(p.owned || ent) x)),
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
end $f$;

-- wear: owning through the pet or through the account both count.
create or replace function private.wear_item_impl(p_slot text, p_item text)
returns jsonb language plpgsql security definer set search_path = '' as $f$
declare uid uuid := auth.uid(); p public.pets;
begin
  if uid is null then raise exception 'Not signed in'; end if;
  if p_slot not in ('hat','outfit') then raise exception 'Unknown slot'; end if;
  select * into p from public.pets where user_id = uid and retired_at is null for update;
  if p.id is null then raise exception 'No pet'; end if;
  if p_item is not null then
    if not (p_item = any(p.owned) or exists (select 1 from public.entitlements e where e.user_id = uid and e.item = p_item)) then
      raise exception 'You do not own this'; end if;
    if (p_slot = 'hat') <> (p_item like 'hat\_%') then raise exception 'Wrong slot'; end if;
  end if;
  update public.pets set hat = case when p_slot = 'hat' then p_item else hat end,
                         outfit = case when p_slot = 'outfit' then p_item else outfit end where id = p.id;
  return private.state(uid);
end $f$;

-- buy with tomatoes: once the paid shop is visible, paid items can no longer be bought with tomatoes.
create or replace function private.buy_item_impl(p_item text)
returns jsonb language plpgsql security definer set search_path = '' as $f$
declare uid uuid := auth.uid(); p public.pets; price int;
begin
  if uid is null then raise exception 'Not signed in'; end if;
  price := private.item_price(p_item);
  if price is null then raise exception 'Unknown item'; end if;
  if private.paid_visible(uid) and exists (select 1 from public.catalog c where c.kind = 'item' and c.active and c.grants = array[p_item]) then
    raise exception 'This item is sold in the shop';
  end if;
  select * into p from public.pets where user_id = uid and retired_at is null for update;
  if p.id is null then raise exception 'No pet'; end if;
  p := private.sync_pet(p, private.today_for(uid));
  if not p.alive then raise exception 'Your pet is out playing. Send a letter first.'; end if;
  if p_item = any(p.owned) then raise exception 'You already have this'; end if;
  if p.fruits < price then raise exception 'You need % tomatoes for this', price; end if;
  update public.pets set fruits = fruits - price, owned = owned || p_item,
         hat = case when p_item like 'hat\_%' then p_item else hat end,
         outfit = case when p_item like 'fit\_%' then p_item else outfit end
   where id = p.id;
  insert into public.pet_events(pet_id, user_id, day, kind, detail)
  values (p.id, uid, private.today_for(uid), 'item_bought', jsonb_build_object('item', p_item, 'price', price));
  return private.state(uid);
end $f$;

-- adopt: validates the species; monkey and reindeer need an entitlement once the paid shop is visible.
create or replace function private.adopt_pet_impl(p_species text)
returns jsonb language plpgsql security definer set search_path = '' as $f$
declare uid uuid := auth.uid(); t date; cur public.pets; np public.pets;
begin
  if uid is null then raise exception 'Not signed in'; end if;
  if p_species is null or p_species not in ('chicken','parrot','pig','hamster','monkey','turtle','snake','fish','reindeer') then
    raise exception 'Unknown pet'; end if;
  if p_species = 'reindeer' and not private.paid_visible(uid) then raise exception 'Unknown pet'; end if;
  if p_species in ('monkey','reindeer') and private.paid_visible(uid)
     and not exists (select 1 from public.entitlements e where e.user_id = uid and e.item = p_species) then
    raise exception 'This pet is sold in the shop'; end if;
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
end $f$;
