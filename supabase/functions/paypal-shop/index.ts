// paypal-shop: creates and captures PayPal orders server-side, then grants entitlements.
// Secrets: PAYPAL_CLIENT_ID, PAYPAL_CLIENT_SECRET, optional PAYPAL_API_BASE (default sandbox).
import { createClient } from 'npm:@supabase/supabase-js@2';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, apikey, content-type, x-client-info',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const json = (b: unknown, status = 200) =>
  new Response(JSON.stringify(b), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });

const API = Deno.env.get('PAYPAL_API_BASE') ?? 'https://api-m.sandbox.paypal.com';
const ALLOWED_RETURN = ['https://tomato-tail-garden-pals.vercel.app/', 'https://tomato-tail-garden-pals.lovable.app/'];
function returnBase(v: unknown): string {
  const s = typeof v === 'string' ? v.split(/[?#]/)[0] : '';
  return ALLOWED_RETURN.includes(s) ? s : ALLOWED_RETURN[0];
}
const admin = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, {
  auth: { persistSession: false },
});

async function paypalToken(): Promise<string> {
  const id = Deno.env.get('PAYPAL_CLIENT_ID')!, sec = Deno.env.get('PAYPAL_CLIENT_SECRET')!;
  const r = await fetch(`${API}/v1/oauth2/token`, {
    method: 'POST',
    headers: { Authorization: 'Basic ' + btoa(`${id}:${sec}`), 'Content-Type': 'application/x-www-form-urlencoded' },
    body: 'grant_type=client_credentials',
  });
  const j = await r.json();
  if (!j.access_token) throw new Error('PayPal auth failed');
  return j.access_token;
}

const dollars = (cents: number) => (cents / 100).toFixed(2);

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { headers: CORS });
  if (req.method !== 'POST') return json({ error: 'Method not allowed' }, 405);
  try {
    const token = (req.headers.get('Authorization') ?? '').replace(/^Bearer\s+/i, '');
    const { data: u, error: ue } = await admin.auth.getUser(token);
    if (ue || !u.user) return json({ error: 'Not signed in' }, 401);
    const uid = u.user.id;
    if (u.user.is_anonymous) {
      const { data: p } = await admin.from('profiles').select('is_test').eq('id', uid).maybeSingle();
      if (!p?.is_test) return json({ error: 'Save your pet with Google before buying' }, 403);
    }
    const body = await req.json().catch(() => ({}));

    if (body.action === 'create') {
      const sku = String(body.sku ?? '');
      const picks = Array.isArray(body.picks) ? body.picks.map(String) : null;
      const { data: prep, error: pe } = await admin.rpc('shop_prepare_order', { p_uid: uid, p_sku: sku, p_picks: picks });
      if (pe) return json({ error: pe.message }, 400);
      const base = returnBase(body.return_url);
      const pt = await paypalToken();
      const r = await fetch(`${API}/v2/checkout/orders`, {
        method: 'POST',
        headers: { Authorization: `Bearer ${pt}`, 'Content-Type': 'application/json', 'PayPal-Request-Id': prep.order_id },
        body: JSON.stringify({
          intent: 'CAPTURE',
          purchase_units: [{
            reference_id: prep.order_id,
            custom_id: prep.order_id,
            description: `Tomatail: ${prep.name}`,
            amount: { currency_code: 'USD', value: dollars(prep.amount_cents) },
          }],
          payment_source: { paypal: { experience_context: {
            shipping_preference: 'NO_SHIPPING', user_action: 'PAY_NOW', brand_name: 'Tomatail',
            return_url: base + '?paypal=return', cancel_url: base + '?paypal=cancel',
          } } },
        }),
      });
      const o = await r.json();
      if (!r.ok || !o.id) {
        await admin.rpc('shop_fail_order', { p_order: prep.order_id });
        return json({ error: 'Could not start checkout' }, 502);
      }
      await admin.from('orders').update({ paypal_order_id: o.id }).eq('id', prep.order_id);
      const approve = (o.links ?? []).find((l: { rel: string }) => l.rel === 'payer-action' || l.rel === 'approve')?.href ?? null;
      return json({ paypal_order_id: o.id, order_id: prep.order_id, approve_url: approve });
    }

    if (body.action === 'capture') {
      const pid = String(body.paypal_order_id ?? '');
      const { data: ord } = await admin.from('orders').select('*').eq('paypal_order_id', pid).eq('user_id', uid).maybeSingle();
      if (!ord) return json({ error: 'Unknown order' }, 404);
      if (ord.status === 'completed') return json({ status: 'completed', already: true });
      if (ord.status !== 'created') return json({ error: 'Order is not payable' }, 409);
      const pt = await paypalToken();
      const r = await fetch(`${API}/v2/checkout/orders/${encodeURIComponent(pid)}/capture`, {
        method: 'POST',
        headers: { Authorization: `Bearer ${pt}`, 'Content-Type': 'application/json', 'PayPal-Request-Id': `cap-${ord.id}` },
        body: '{}',
      });
      const c = await r.json();
      const pu = c?.purchase_units?.[0];
      const cap = pu?.payments?.captures?.[0];
      const okAmount = cap && cap.amount?.currency_code === 'USD' && cap.amount?.value === dollars(ord.amount_cents);
      if (r.ok && c.status === 'COMPLETED' && cap?.status === 'COMPLETED' && okAmount && (pu.custom_id ?? pu.reference_id) === ord.id) {
        const { data: done, error: de } = await admin.rpc('shop_complete_order', { p_order: ord.id, p_paypal_order: pid, p_capture: cap.id });
        if (de) return json({ error: 'Payment taken but grant failed; contact support', order_id: ord.id }, 500);
        return json(done);
      }
      if (cap?.status === 'PENDING') return json({ status: 'pending' }, 202);
      return json({ error: 'Payment was not completed' }, 402);
    }
    return json({ error: 'Unknown action' }, 400);
  } catch (e) {
    console.error(String(e));
    return json({ error: 'Server error' }, 500);
  }
});
