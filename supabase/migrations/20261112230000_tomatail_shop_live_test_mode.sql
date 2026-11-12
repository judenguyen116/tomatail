-- payments_mode 'live_test': real PayPal (live credentials) but the shop is visible only to is_test profiles.
-- Used for the first real $0.50 payment and refund test before opening to everyone with 'live'.
create or replace function private.paid_visible(p_uid uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select case (select value from private.config where key = 'payments_mode')
    when 'live' then true
    when 'sandbox' then coalesce((select is_test from public.profiles where id = p_uid), false)
    when 'live_test' then coalesce((select is_test from public.profiles where id = p_uid), false)
    else false end
$$;
