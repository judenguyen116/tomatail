# Load test (30 guest players)
    cd tools/load && npm i @supabase/supabase-js && node load.cjs 30 <label>
Each virtual player: guest sign-in, adopt pet, 4 tasks (3 min sit), buy, click, mood. Writes result_<label>.json.
Supabase limits anonymous sign-ins to 30/hour/IP, so run at most one batch of 30 per hour.
Afterwards mark the bots: update public.profiles set is_test=true where id in (select id from auth.users where is_anonymous and created_at > now() - interval '40 minutes');
