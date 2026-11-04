# Tomatail on Supabase

Project: `tomatail` (ref `wqdiglfdolqelyvidslp`, region ap-southeast-1)
API URL: https://wqdiglfdolqelyvidslp.supabase.co

The game rules run inside the database, so a player cannot give themselves extra tomatoes from the browser. The client reads its own rows and changes state only through the RPC functions below.

## Tables
| Table | What it holds |
|---|---|
| `profiles` | One row per user (created automatically on sign-up): email, time zone |
| `pets` | Each pet a user has had, with its optional `name`. One active pet per user (`retired_at is null`). Happiness, tomatoes, rescues, streak, alive/dead |
| `daily_checkins` | One row per pet per day: which of the 4 tasks are done, meditation start time, whether the day was rewarded |
| `logins` | Every visit, with the user's local day |
| `pet_events` | History: created, retired, browser reminder, email reminder, death, rescue (with the letter), valid check-in |

Row Level Security: signed-in users can only read their own rows. Nobody can insert or update tables directly.

## RPC functions (call with `supabase.rpc(name, args)`)
| Function | Does |
|---|---|
| `record_login()` | Counts a visit (at most one per minute); voids an unfinished day (leaving early does not count) |
| `get_state()` | Returns today, time zone, logins today, pet, today's tasks |
| `adopt_pet(p_species)` | New pet. Refused if the current pet is alive, or dead with rescues left |
| `start_meditation()` | Records when the 10-minute session started |
| `complete_task(p_task)` | `feed`, `water`, `play`, `meditate` (needs 10 minutes since start). All 4 done = +1 tomato and +1 happiness, once per day. Returns `valid` and `gift` (7-day streak) |
| `rescue_pet(p_letter)` | Brings a dead pet back; max 5 per pet; plant restarts at 0 |
| `set_timezone(p_tz)` | Changes the user's time zone (IANA name). First set is free, then once every 7 days. Changing zone cannot open a second rewarded day |
| `set_pet_name(p_name)` | Names the current pet (1-20 characters, trimmed; empty clears it). Logged as a `renamed` event |
| `retire_pet()` | Prototype tool: give up the current pet |

The day is computed from the user's time zone on the server.

## Scheduled job
`tomatail-sync-all` (pg_cron, every hour at :17) applies absences for all pets, records reminder events at day 1 and day 6, and marks pets dead at day 7, even if the player never comes back. Sending the actual email is not built yet.
