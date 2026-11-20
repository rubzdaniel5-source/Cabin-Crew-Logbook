// send-push — delivers queued phone/browser push notifications (Web Push, VAPID).
//   GET  -> { publicKey }                    (the app reads this to subscribe a phone)
//   POST -> x-cron-secret header; delivers the queue (scheduled every minute)
// Secrets: VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY, VAPID_SUBJECT (mailto:you@domain), CRON_SECRET, APP_URL

const CORS = { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'content-type, x-cron-secret' };
export const json = (b: unknown, status = 200) => new Response(JSON.stringify(b), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });

export interface Env { SUPABASE_URL?: string; SUPABASE_SERVICE_ROLE_KEY?: string; VAPID_PUBLIC_KEY?: string;
  VAPID_PRIVATE_KEY?: string; VAPID_SUBJECT?: string; CRON_SECRET?: string; APP_URL?: string }
export interface Sub { id: string; endpoint: string; p256dh: string; auth: string }
export interface Job { ids: string[]; title: string; body: string; tag: string; subs: Sub[] }
export type Sender = (sub: Sub, payload: string) => Promise<{ status: number }>;

export async function handle(req: Request, env: Env, makeClient: (u: string, k: string) => Promise<any>,
                             makeSender: () => Promise<Sender>): Promise<Response> {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method === 'GET') return env.VAPID_PUBLIC_KEY ? json({ publicKey: env.VAPID_PUBLIC_KEY }) : json({ error: 'Push is not configured' }, 503);
  if (req.method !== 'POST') return json({ error: 'Not allowed' }, 405);
  if (!env.CRON_SECRET || req.headers.get('x-cron-secret') !== env.CRON_SECRET) return json({ error: 'Not allowed' }, 401);
  if (!env.VAPID_PUBLIC_KEY || !env.VAPID_PRIVATE_KEY || !env.SUPABASE_URL || !env.SUPABASE_SERVICE_ROLE_KEY)
    return json({ error: 'Push is not configured yet (VAPID keys missing). Notifications stay queued.' }, 503);

  const db = await makeClient(env.SUPABASE_URL, env.SUPABASE_SERVICE_ROLE_KEY);
  const { data: jobs, error } = await db.rpc('push_claim_batch', { p_limit: 50 });
  if (error) return json({ error: 'claim failed: ' + error.message }, 500);
  const send = await makeSender();
  let sent = 0, retried = 0, failed = 0, gone = 0;

  for (const job of (jobs || []) as Job[]) {
    if (!job.subs.length) { await db.rpc('push_mark', { p_ids: job.ids, p_state: 'sent', p_error: null }); sent++; continue; }
    const payload = JSON.stringify({ title: job.title, body: job.body, tag: job.tag, url: env.APP_URL || '/' });
    let delivered = 0, transient = '', permanent = '';
    for (const s of job.subs) {
      try {
        const r = await send(s, payload);
        if (r.status >= 200 && r.status < 300) { delivered++; await db.rpc('push_sub_result', { p_id: s.id, p_gone: false }); }
        else if (r.status === 404 || r.status === 410) { gone++; await db.rpc('push_sub_result', { p_id: s.id, p_gone: true }); }
        else if (r.status === 429 || r.status >= 500) transient = 'push service ' + r.status;
        else permanent = 'push service ' + r.status;
      } catch (e) {
        const st = (e as any)?.statusCode;
        if (st === 404 || st === 410) { gone++; await db.rpc('push_sub_result', { p_id: s.id, p_gone: true }); }
        else if (st && st >= 400 && st < 500 && st !== 429) permanent = 'push service ' + st;
        else transient = String((e as Error)?.message || e);
      }
    }
    // Delivered to at least one device, or every device had been removed -> done
    if (delivered > 0 || (!transient && !permanent)) { await db.rpc('push_mark', { p_ids: job.ids, p_state: 'sent', p_error: null }); sent++; }
    else if (transient) { await db.rpc('push_mark', { p_ids: job.ids, p_state: 'retry', p_error: transient }); retried++; }
    else { await db.rpc('push_mark', { p_ids: job.ids, p_state: 'failed', p_error: permanent }); failed++; }
  }
  return json({ claimed: (jobs || []).length, sent, retried, failed, removed_devices: gone });
}

const D = (globalThis as any).Deno;
if (D?.serve) {
  D.serve((req: Request) => {
    const env = D.env.toObject();
    return handle(req, env, async (url, key) => {
      const { createClient } = await import('https://esm.sh/@supabase/supabase-js@2');
      return createClient(url, key, { auth: { persistSession: false } });
    }, async () => {
      const wp = (await import('npm:web-push@3.6.7')).default;
      wp.setVapidDetails(env.VAPID_SUBJECT || 'mailto:admin@example.com', env.VAPID_PUBLIC_KEY, env.VAPID_PRIVATE_KEY);
      return (sub, payload) => wp.sendNotification({ endpoint: sub.endpoint, keys: { p256dh: sub.p256dh, auth: sub.auth } }, payload, { TTL: 86400, urgency: 'high' });
    });
  });
}
