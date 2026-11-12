-- Step 2: server-side order helpers used only by the paypal-shop Edge Function (service role).
-- Clients cannot call these; money state is written nowhere else.

create or replace function public.shop_prepare_order(p_uid uuid, p_sku text, p_picks text[])
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare c public.catalog%rowtype; oid uuid; want text[]; today date := (now() at time zone 'utc')::date;
        hats int; fits int; owned text[];
begin
  if not private.paid_visible(p_uid) then raise exception 'Shop is closed'; end if;
  select * into c from public.catalog where sku = p_sku and active;
  if not found then raise exception 'Unknown item'; end if;
  if (c.sale_start is not null and today < c.sale_start) or (c.sale_end is not null and today > c.sale_end) then
    raise exception 'Not on sale right now';
  end if;
  select coalesce(array_agg(item), '{}') into owned from public.entitlements where user_id = p_uid;
  if c.rule = 'one_hat_one_outfit' then
    if p_picks is null or cardinality(p_picks) <> 2 or not (p_picks <@ c.grants) then raise exception 'Pick one hat and one outfit'; end if;
    select count(*) filter (where x like 'hat\_%'), count(*) filter (where x like 'fit\_%') into hats, fits from unnest(p_picks) x;
    if hats <> 1 or fits <> 1 or p_picks[1] = p_picks[2] then raise exception 'Pick one hat and one outfit'; end if;
    want := p_picks;
  else
    want := c.grants;
  end if;
  if want <@ owned then raise exception 'You already own this'; end if;
  insert into public.orders (user_id, sku, picks, amount_cents, status)
    values (p_uid, p_sku, case when c.rule is null then null else p_picks end, c.price_cents, 'created')
    returning id into oid;
  return jsonb_build_object('order_id', oid, 'amount_cents', c.price_cents, 'name', c.name);
end $$;

create or replace function public.shop_complete_order(p_order uuid, p_paypal_order text)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare o public.orders%rowtype; c public.catalog%rowtype; want text[];
begin
  select * into o from public.orders where id = p_order for update;
  if not found then raise exception 'Unknown order'; end if;
  if o.status = 'completed' then return jsonb_build_object('status', 'completed', 'already', true); end if;
  select * into c from public.catalog where sku = o.sku;
  want := coalesce(o.picks, c.grants);
  insert into public.entitlements (user_id, item, sku, order_id, source)
    select o.user_id, x, o.sku, o.id, 'paypal' from unnest(want) x
    on conflict (user_id, item) do nothing;
  update public.orders set status = 'completed', completed_at = now(),
         paypal_order_id = coalesce(paypal_order_id, p_paypal_order) where id = o.id;
  return jsonb_build_object('status', 'completed', 'granted', to_jsonb(want));
end $$;

create or replace function public.shop_fail_order(p_order uuid) returns void
language sql security definer set search_path = '' as $$
  update public.orders set status = 'failed' where id = p_order and status = 'created';
$$;

revoke all on function public.shop_prepare_order(uuid, text, text[]) from public, anon, authenticated;
revoke all on function public.shop_complete_order(uuid, text) from public, anon, authenticated;
revoke all on function public.shop_fail_order(uuid) from public, anon, authenticated;
grant execute on function public.shop_prepare_order(uuid, text, text[]) to service_role;
grant execute on function public.shop_complete_order(uuid, text) to service_role;
grant execute on function public.shop_fail_order(uuid) to service_role;
