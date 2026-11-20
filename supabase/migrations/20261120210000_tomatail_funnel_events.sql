-- Funnel tracking: more click kinds so we can see shop opens, save-pet clicks and buy starts.
alter table public.click_events drop constraint if exists click_events_kind_check;
alter table public.click_events add constraint click_events_kind_check
  check (kind = any (array['donate_open','donate_paypal','shop_open','save_click_shop','save_click_other','buy_start','ext_handoff']));

create or replace function public.log_click(p_kind text)
 returns void
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare uid uuid := auth.uid();
begin
  if p_kind not in ('donate_open','donate_paypal','shop_open','save_click_shop','save_click_other','buy_start','ext_handoff') then return; end if;
  if uid is null then
    -- soft cap so anonymous callers cannot flood the table
    if (select count(*) from public.click_events where user_id is null and created_at > now() - interval '1 hour') >= 300 then return; end if;
  else
    -- at most one row per player, kind and 10 seconds
    if exists (select 1 from public.click_events where user_id = uid and kind = p_kind and created_at > now() - interval '10 seconds') then return; end if;
  end if;
  insert into public.click_events(user_id, kind) values (uid, p_kind);
end $function$;
