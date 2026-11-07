

const { createClient } = require('@supabase/supabase-js');
const URL_ = 'https://wqdiglfdolqelyvidslp.supabase.co';
const KEY = 'sb_publishable_LAnwCY59ami4q7yMIH7sPw_4hPyyE9f';
const N = +process.argv[2] || 30, SIT = 3;
const SP = ['chicken','parrot','pig','hamster','monkey','turtle','snake','fish'];
const lat = {}; const errs = []; const ids = [];
const sleep = ms => new Promise(r => setTimeout(r, ms));
async function call(sb, name, fn, args) {
  const t = Date.now();
  const { data, error } = await sb.rpc(fn, args || {});
  (lat[name] ||= []).push(Date.now() - t);
  if (error) { errs.push(name + ': ' + error.message); return null; }
  return data;
}
async function user(i) {
  const sb = createClient(URL_, KEY, { auth: { persistSession: false, autoRefreshToken: false } });
  let t = Date.now();
  const { data, error } = await sb.auth.signInAnonymously();
  (lat.signin ||= []).push(Date.now() - t);
  if (error) { errs.push('signin: ' + error.message); return 'signin_fail'; }
  ids.push(data.user.id);
  await sleep(Math.random() * 3000);
  await call(sb, 'record_login', 'record_login');
  await call(sb, 'set_timezone', 'set_timezone', { p_tz: 'Asia/Ho_Chi_Minh' });
  await call(sb, 'adopt_pet', 'adopt_pet', { p_species: SP[i % SP.length] });
  await call(sb, 'get_state', 'get_state');
  for (const k of ['feed', 'water', 'play']) { await sleep(500 + Math.random() * 1500); await call(sb, 'complete_task', 'complete_task', { p_task: k }); }
  await call(sb, 'start_meditation', 'start_meditation', { p_minutes: SIT });
  const end = Date.now() + SIT * 60000 + 3000;
  while (Date.now() < end) { await sleep(20000); await call(sb, 'med_ping', 'med_ping'); }
  const st = await call(sb, 'complete_task', 'complete_task', { p_task: 'meditate' });
  await call(sb, 'get_state', 'get_state');
  await call(sb, 'buy_item', 'buy_item', { p_item: 'hat_cap' });
  await call(sb, 'log_click', 'log_click', { p_kind: 'donate_open' });
  const m = await sb.rpc('save_mood', { p_mood: 'happy', p_note: 'load test' }); (lat.save_mood ||= []).push(0);
  return st && st.valid ? 'ok' : 'done_not_valid';
}
(async () => {
  const t0 = Date.now();
  const res = await Promise.all(Array.from({ length: N }, (_, i) => user(i).catch(e => { errs.push('crash: ' + e.message); return 'crash'; })));
  const q = (a, p) => { a = [...a].sort((x, y) => x - y); return a[Math.min(a.length - 1, Math.floor(a.length * p))]; };
  const out = { users: N, seconds: Math.round((Date.now() - t0) / 1000), results: res.reduce((m, r) => (m[r] = (m[r] || 0) + 1, m), {}), latency_ms: {}, errors: errs.reduce((m, e) => (m[e] = (m[e] || 0) + 1, m), {}), ids };
  for (const k in lat) out.latency_ms[k] = { n: lat[k].length, p50: q(lat[k], .5), p95: q(lat[k], .95), max: Math.max(...lat[k]) };
  require('fs').writeFileSync('result_' + process.argv[3] + '.json', JSON.stringify(out, null, 1));
  console.log(JSON.stringify({ ...out, ids: undefined }, null, 1));
})();
