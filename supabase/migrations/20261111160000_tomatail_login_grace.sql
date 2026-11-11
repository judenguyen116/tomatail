-- record_login used to wipe today's unrewarded tasks on every visit, so a page reload
-- (common on phones) lost progress. Now the reset only happens when the last activity
-- on the check-in is older than 30 minutes.
create or replace function private.record_login_impl()
returns jsonb
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
   where user_id = uid and day = t and not rewarded
     and updated_at < now() - interval '30 minutes';
  return private.state(uid);
end $$;
