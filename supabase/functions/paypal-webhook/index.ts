// paypal-webhook: PayPal tells us about payments we did not see end to end.
// - PAYMENT.CAPTURE.COMPLETED : a payment that was pending is now final -> grant the order
// - PAYMENT.CAPTURE.DENIED    : mark the order failed
// - PAYMENT.CAPTURE.REFUNDED  : full refund -> take the items back (partial refunds are kept)
// - PAYMENT.CAPTURE.REVERSED  : chargeback -> take the items back
// Secrets: PAYPAL_CLIENT_ID, PAYPAL_CLIENT_SECRET, PAYPAL_WEBHOOK_ID, optional PAYPAL_API_BASE.
import { createClient } from 'npm:@supabase/supabase-js@2';

const API = Deno.env.get('PAYPAL_API_BASE') ?? 'https://api-m.sandbox.paypal.com';
const admin = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, {
  auth: { persistSession: false },
});
const ok = (b: unknown = { ok: true }, status = 200) =>
  new Response(JSON.stringify(b), { status, headers: { 'Content-Type': 'application/json' } });

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

async function verified(req: Request, event: unknown, webhookId: string): Promise<boolean> {
  const h = (n: string) => req.headers.get(n) ?? '';
  const r = await fetch(`${API}/v1/notifications/verify-webhook-signature`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${await paypalToken()}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({
      auth_algo: h('paypal-auth-algo'), cert_url: h('paypal-cert-url'),
      transmission_id: h('paypal-transmission-id'), transmission_sig: h('paypal-transmission-sig'),
      transmission_time: h('paypal-transmission-time'), webhook_id: webhookId, webhook_event: event,
    }),
  });
  const j = await r.json().catch(() => ({}));
  return r.ok && j.verification_status === 'SUCCESS';
}

const cents = (v: unknown) => Math.round(parseFloat(String(v)) * 100);
const lastSegment = (href: string) => href.split('?')[0].split('/').filter(Boolean).pop() ?? '';

Deno.serve(async (req) => {
  if (req.method !== 'POST') return ok({ error: 'Method not allowed' }, 405);
  const webhookId = Deno.env.get('PAYPAL_WEBHOOK_ID');
  if (!webhookId) return ok({ error: 'Webhook not configured' }, 503);
  const raw = await req.text();
  let event: { event_type?: string; resource?: Record<string, any> };
  try { event = JSON.parse(raw); } catch { return ok({ error: 'Bad body' }, 400); }
  try {
    if (!(await verified(req, event, webhookId))) return ok({ error: 'Bad signature' }, 401);
    const type = event.event_type ?? '';
    const r = event.resource ?? {};
    let captureId = '', custom = '';
    if (type === 'PAYMENT.CAPTURE.REFUNDED') {
      const up = (r.links ?? []).find((l: { rel: string }) => l.rel === 'up')?.href;
      captureId = up ? lastSegment(up) : '';
    } else {
      captureId = String(r.id ?? ''); custom = String(r.custom_id ?? '');
    }
    if (!['PAYMENT.CAPTURE.COMPLETED', 'PAYMENT.CAPTURE.DENIED', 'PAYMENT.CAPTURE.REFUNDED', 'PAYMENT.CAPTURE.REVERSED'].includes(type)) return ok({ ignored: type });
    const { data: ord, error: fe } = await admin.rpc('shop_find_order', { p_capture: captureId || null, p_custom: custom || null });
    if (fe) throw fe;
    if (!ord || !ord.id) return ok({ ignored: 'not our order' });

    if (type === 'PAYMENT.CAPTURE.COMPLETED') {
      if (ord.status === 'refunded' || ord.status === 'failed') return ok({ ignored: ord.status });
      if (r.status === 'COMPLETED' && r.amount?.currency_code === 'USD' && cents(r.amount?.value) === ord.amount_cents) {
        const { error } = await admin.rpc('shop_complete_order', { p_order: ord.id, p_paypal_order: ord.paypal_order_id, p_capture: captureId });
        if (error) throw error;
      }
    } else if (type === 'PAYMENT.CAPTURE.DENIED') {
      const { error } = await admin.rpc('shop_revoke_order', { p_order: ord.id, p_status: 'failed' });
      if (error) throw error;
    } else if (type === 'PAYMENT.CAPTURE.REVERSED') {
      const { error } = await admin.rpc('shop_revoke_order', { p_order: ord.id, p_status: 'refunded' });
      if (error) throw error;
    } else if (type === 'PAYMENT.CAPTURE.REFUNDED') {
      if (cents(r.amount?.value) >= ord.amount_cents) {
        const { error } = await admin.rpc('shop_revoke_order', { p_order: ord.id, p_status: 'refunded' });
        if (error) throw error;
      } else {
        console.log('partial refund kept', ord.id);
      }
    }
    return ok();
  } catch (e) {
    console.error(String(e));
    return ok({ error: 'Server error' }, 500); // PayPal will retry
  }
});
