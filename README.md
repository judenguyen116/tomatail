# Tomatail

A pixel-art virtual exotic pet that waters tomatoes while you're away. Daily check-in (feed, water, play, meditate 10 min), happiness stat, tomato plant that wilts, death and rescue mechanic, procedural lofi music.

Single static file: open `index.html` in a browser.

## Online mode (Supabase)
- When served from a normal web host (GitHub Pages, Vercel), the game uses Supabase for accounts (email + password, Google, password reset) and saves the pet on the server. Game rules run in the database; see `supabase/README.md`.
- If Supabase cannot load (or `ONLINE_ALLOWED` is false), the game falls back to the local demo: accounts and pets live in the browser's localStorage, with the Time machine tools.
- Before going live, in the Supabase dashboard set Authentication > URL Configuration > Site URL (and Redirect URLs) to the deployed address, so confirmation and reset links come back to the game.

## Prototype status
- Browser notifications and the day-6 email are recorded as events; real sending is not built yet.
- Music is generated with WebAudio (placeholder). Pet art is placeholder.
- Use Tools > Time machine to jump days and see sad, wilting and death states.

## Test game logic
`node test-logic.js` (extracts the logic block from `index.html` and runs scenarios).
