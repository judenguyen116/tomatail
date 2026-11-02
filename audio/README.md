# Lofi library

Put licensed audio files here (mp3 or ogg), then add one line per track to the `LIBRARY` array in `index.html`:

```js
{ title:'Track name', artist:'Artist', src:'audio/track.mp3', license:'CC0', url:'https://where-you-got-it' }
```

Only add tracks whose license allows use on a monetized website. Keep the `license` and `url` fields filled in: the player shows them as credit. Tracks play before the built-in generated sketches.
