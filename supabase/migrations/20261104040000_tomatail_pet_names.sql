-- Pet names live on the server so they follow the player across devices.
alter table public.pets add column if not exists name text;
alter table public.pets drop constraint if exists pets_name_check;
alter table public.pets add constraint pets_name_check
  check (name is null or (char_length(name) between 1 and 20 and name = btrim(name) and name !~ '[[:cntrl:]<>]'));

alter table public.pet_events drop constraint if exists pet_events_kind_check;
alter table public.pet_events add constraint pet_events_kind_check
  check (kind in ('created','retired','browser','email','death','rescue','valid_checkin','renamed'));

-- Set or clear (null / empty) the name of the current pet.
create or replace function public.set_pet_name(p_name text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid(); t date; p public.pets; n text;
begin
  if uid is null then raise exception 'Not signed in'; end if;
  n := nullif(regexp_replace(btrim(coalesce(p_name, '')), '\s+', ' ', 'g'), '');
  if n is not null then
    if char_length(n) > 20 then raise exception 'Pet names can be up to 20 characters'; end if;
    if n ~ '[[:cntrl:]<>]' then raise exception 'Please use letters, numbers and simple punctuation'; end if;
  end if;
  t := private.today_for(uid);
  select * into p from public.pets where user_id = uid and retired_at is null for update;
  if p.id is null then raise exception 'No pet'; end if;
  if p.name is distinct from n then
    update public.pets set name = n where id = p.id;
    insert into public.pet_events(pet_id, user_id, day, kind, detail)
      values (p.id, uid, t, 'renamed', jsonb_build_object('from', p.name, 'to', n));
  end if;
  return private.state(uid);
end $$;
revoke all on function public.set_pet_name(text) from public, anon;
grant execute on function public.set_pet_name(text) to authenticated;
