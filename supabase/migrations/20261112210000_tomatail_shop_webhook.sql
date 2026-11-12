-- Webhook support: capture ids on orders, grant-on-late-completion, and revoke on refund/chargeback.
alter table public.orders add column if not exists capture_id text;
create unique index if not exists orders_capture_id_key on public.orders (capture_id) where capture_id is not null;

drop function if exists public.shop_complete_order(uuid, text);
create or replace function public.shop_complete_order(p_order uuid, p_paypal_order text, p_capture text default null)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare o public.orders%rowtype; c public.catalog%rowtype; want text[];
begin
  select * into o from public.orders where id = p_order for update;
  if not found then raise exception 'Unknown order'; end if;
  if o.status = 'completed' then
    if p_capture is not null and o.capture_id is null then update public.orders set capture_id = p_capture where id = o.id; end if;
    return jsonb_build_object('status', 'completed', 'already', true);
  end if;
  if o.status in ('refunded', 'failed') and p_capture is null then raise exception 'Order is closed'; end if;
  select * into c from public.catalog where sku = o.sku;
  want := coalesce(o.picks, c.grants);
  insert into public.entitlements (user_id, item, sku, order_id, source)
    select o.user_id, x, o.sku, o.id, 'paypal' from unnest(want) x
    on conflict (user_id, item) do nothing;
  update public.orders set status = 'completed', completed_at = now(),
         paypal_order_id = coalesce(paypal_order_id, p_paypal_order), capture_id = coalesce(p_capture, capture_id) where id = o.id;
  return jsonb_build_object('status', 'completed', 'granted', to_jsonb(want));
end $$;

create or replace function public.shop_find_order(p_capture text, p_custom text)
returns public.orders
language plpgsql security definer set search_path = '' as $$
declare o public.orders%rowtype; cid uuid;
begin
  if p_capture is not null then select * into o from public.orders where capture_id = p_capture; end if;
  if o.id is null and p_custom is not null then
    begin cid := p_custom::uuid; exception when others then cid := null; end;
    if cid is not null then select * into o from public.orders where id = cid; end if;
  end if;
  return o;
end $$;

create or replace function public.shop_revoke_order(p_order uuid, p_status text)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare items text[];
begin
  if p_status not in ('refunded', 'failed') then raise exception 'bad status'; end if;
  select coalesce(array_agg(item), '{}') into items from public.entitlements where order_id = p_order;
  delete from public.entitlements where order_id = p_order;
  update public.pets pt set hat = case when pt.hat = any(items) and not (pt.hat = any(pt.owned)) then null else pt.hat end,
                          outfit = case when pt.outfit = any(items) and not (pt.outfit = any(pt.owned)) then null else pt.outfit end
   where pt.user_id = (select user_id from public.orders where id = p_order) and pt.retired_at is null;
  update public.orders set status = p_status where id = p_order and status <> p_status;
  return jsonb_build_object('revoked', to_jsonb(items), 'status', p_status);
end $$;

revoke all on function public.shop_complete_order(uuid, text, text) from public, anon, authenticated;
revoke all on function public.shop_find_order(text, text) from public, anon, authenticated;
revoke all on function public.shop_revoke_order(uuid, text) from public, anon, authenticated;
grant execute on function public.shop_complete_order(uuid, text, text) to service_role;
grant execute on function public.shop_find_order(text, text) to service_role;
grant execute on function public.shop_revoke_order(uuid, text) to service_role;
