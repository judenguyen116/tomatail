# Tomatail

A pixel-art virtual exotic pet that waters tomatoes while you're away. Daily check-in (feed, water, play, meditate 10 min), happiness stat, tomato plant that wilts, death and rescue mechanic, procedural lofi music.

Single static file: open `index.html` in a browser.

## Prototype status
- Login, OTP reset, notifications and emails are simulated in the browser (localStorage). Nothing is sent anywhere.
- Music is generated with WebAudio (placeholder). Pet art is placeholder.
- Use Tools > Time machine to jump days and see sad, wilting and death states.

## Test game logic
`node test-logic.js` (extracts the logic block from `index.html` and runs scenarios).
