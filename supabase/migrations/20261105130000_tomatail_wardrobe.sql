-- Wardrobe: spend tomatoes on hats and outfits.
alter table public.pets add column owned text[] not null default '{}', add column hat text, add column outfit text;

create or replace function private.item_price(p_item text) returns int language sql immutable set search_path = '' as $$
  select case p_item
    when 'hat_cap' then 3 when 'hat_bow' then 4 when 'hat_straw' then 5 when 'hat_party' then 6 when 'hat_wizard' then 8 when 'hat_crown' then 10
    when 'fit_scarf' then 3 when 'fit_vest' then 4 when 'fit_overalls' then 5 when 'fit_hoodie' then 6 when 'fit_cape' then 8 when 'fit_kimono' then 10
  end
$$;

alter table public.pet_events drop constraint pet_events_kind_check;
alter table public.pet_events add constraint pet_events_kind_check check (kind in
 ('created','retired','browser','email','death','rescue','valid_checkin','renamed','task','meditation_started','meditation_resumed',
  'repair_used','repair_earned','vacation_started','vacation_ended','adventure_started','adventure_collected','item_bought'));

create or replace function public.buy_item(p_item text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid(); p public.pets; price int;
begin
  if uid is null then raise exception 'Not signed in'; end if;
  price := private.item_price(p_item);
  if price is null then raise exception 'Unknown item'; end if;
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
end $$;

create or replace function public.wear_item(p_slot text, p_item text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid(); p public.pets;
begin
  if uid is null then raise exception 'Not signed in'; end if;
  if p_slot not in ('hat','outfit') then raise exception 'Unknown slot'; end if;
  select * into p from public.pets where user_id = uid and retired_at is null for update;
  if p.id is null then raise exception 'No pet'; end if;
  if p_item is not null then
    if not (p_item = any(p.owned)) then raise exception 'You do not own this'; end if;
    if (p_slot = 'hat') <> (p_item like 'hat\_%') then raise exception 'Wrong slot'; end if;
  end if;
  update public.pets set hat = case when p_slot = 'hat' then p_item else hat end,
                         outfit = case when p_slot = 'outfit' then p_item else outfit end where id = p.id;
  return private.state(uid);
end $$;
revoke all on function public.buy_item(text), public.wear_item(text, text) from public, anon;
grant execute on function public.buy_item(text), public.wear_item(text, text) to authenticated;
