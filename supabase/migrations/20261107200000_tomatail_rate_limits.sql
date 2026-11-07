-- Rate limits for every game RPC, keyed per account AND per IP.
-- Original functions move to the private schema as <name>_impl; thin public wrappers check limits first.

create table if not exists private.rate_hits (
  key text not null, win timestamptz not null, n int not null default 0,
  primary key (key, win)
);
alter table private.rate_hits enable row level security;

create or replace function private.client_ip() returns text
language plpgsql stable security definer set search_path = '' as $$
declare h jsonb; ip text;
begin
  begin h := current_setting('request.headers', true)::jsonb; exception when others then return null; end;
  if h is null then return null; end if;
  ip := coalesce(nullif(h->>'cf-connecting-ip',''), nullif(h->>'x-real-ip',''), nullif(split_part(coalesce(h->>'x-forwarded-for',''), ',', 1),''));
  return nullif(btrim(ip), '');
end $$;

-- fixed one-minute windows; raises when the count passes the limit
create or replace function private.rate_hit(p_key text, p_limit int, p_secs int default 60) returns void
language plpgsql security definer set search_path = '' as $$
declare w timestamptz := to_timestamp(floor(extract(epoch from now()) / p_secs) * p_secs); c int;
begin
  insert into private.rate_hits(key, win, n) values (p_key, w, 1)
  on conflict (key, win) do update set n = private.rate_hits.n + 1 returning n into c;
  if c > p_limit then raise exception 'Too many requests. Please slow down a little.' using errcode = 'P0001'; end if;
  if random() < 0.01 then delete from private.rate_hits where win < now() - interval '2 hours'; end if;
end $$;

-- p_user: per-account limit per minute; p_ip: shared per-IP limit per minute (all functions together)
create or replace function private.rate_guard(p_fn text, p_user int, p_ip int default 600) returns void
language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid(); ip text := private.client_ip();
begin
  if uid is not null then perform private.rate_hit('u:' || uid || ':' || p_fn, p_user); end if;
  if ip is not null then perform private.rate_hit('ip:' || ip, p_ip); end if;
end $$;

do $do$
declare r record;
begin
  for r in select * from (values
    ('adopt_pet','p_species text','p_species',5),
    ('buy_item','p_item text','p_item',10),
    ('collect_adventure','','',10),
    ('complete_task','p_task text','p_task',20),
    ('end_vacation','','',6),
    ('get_state','','',30),
    ('med_ping','','',10),
    ('record_login','','',6),
    ('rescue_pet','p_letter text','p_letter',5),
    ('retire_pet','','',3),
    ('save_mood','p_mood text, p_note text DEFAULT NULL::text','p_mood, p_note',6),
    ('set_mood_reply','p_entry_id uuid, p_reply text','p_entry_id, p_reply',6),
    ('set_pet_name','p_name text','p_name',10),
    ('set_timezone','p_tz text','p_tz',6),
    ('start_meditation','p_minutes integer DEFAULT 10','p_minutes',6),
    ('start_vacation','','',6),
    ('wear_item','p_slot text, p_item text','p_slot, p_item',20)
  ) as t(fn, sig, callargs, lim)
  loop
    declare idsig text := regexp_replace(r.sig, '\s+DEFAULT\s+[^,]+', '', 'g');
    begin
      execute format('alter function public.%I(%s) rename to %I', r.fn, idsig, r.fn || '_impl');
      execute format('alter function public.%I(%s) set schema private', r.fn || '_impl', idsig);
      execute format('revoke all on function private.%I(%s) from public, anon, authenticated', r.fn || '_impl', idsig);
      if r.fn = 'med_ping' then
        execute format($f$create function public.%I(%s) returns void language plpgsql security definer set search_path = '' as $b$
          begin perform private.rate_guard(%L, %s); perform private.%I(%s); end $b$ $f$,
          r.fn, r.sig, r.fn, r.lim, r.fn || '_impl', r.callargs);
      else
        execute format($f$create function public.%I(%s) returns jsonb language plpgsql security definer set search_path = '' as $b$
          begin perform private.rate_guard(%L, %s); return private.%I(%s); end $b$ $f$,
          r.fn, r.sig, r.fn, r.lim, r.fn || '_impl', r.callargs);
      end if;
      execute format('revoke all on function public.%I(%s) from public, anon', r.fn, idsig);
      execute format('grant execute on function public.%I(%s) to authenticated, service_role', r.fn, idsig);
    end;
  end loop;
end $do$;
