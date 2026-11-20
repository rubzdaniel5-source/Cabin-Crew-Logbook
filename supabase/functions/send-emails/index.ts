// send-emails — delivers the queued crew emails (roster changes, messages, leave decisions).
// Called every minute by a schedule (see README.md). Protected by the CRON_SECRET header.
//
// Secrets: RESEND_API_KEY, EMAIL_FROM ("Crew Logbook <crew@yourdomain>"), CRON_SECRET, APP_URL
// (SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are provided by Supabase.)

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'content-type, x-cron-secret',
};

export function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });
}

export function esc(s: unknown): string {
  return String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c] as string));
}

const CHANGE_LABEL: Record<string, string> = {
  activated: 'Activated', assigned: 'Assigned', stood_down: 'Stood down', type_changed: 'Duty type changed',
  delayed: 'Delayed', retimed: 'Re-timed', postponed: 'Postponed', cancelled: 'Cancelled', removed: 'Removed',
  reinstated: 'Reinstated', flight_changed: 'Flight changed', swapped: 'Swapped', no_show: 'No-show',
  reopened: 'Re-opened', added: 'Added', edited: 'Edited',
};
const LEAVE_LABEL: Record<string, string> = {
  annual: 'Annual leave', sick: 'Sick leave', compassionate: 'Compassionate leave', study: 'Study leave',
  maternity: 'Maternity leave', unpaid: 'Unpaid leave', off: 'Day(s) off', other: 'Leave',
};

export interface Job { kind: string; ids: string[]; to_email: string; to_name?: string; items: any[] }
export interface Mail { subject: string; html: string; text: string }

function shell(appUrl: string, title: string, inner: string): string {
  const link = appUrl ? `<p style="margin:24px 0 0"><a href="${esc(appUrl)}" style="color:#0b5ed7">Open Crew Logbook</a></p>` : '';
  return `<div style="font-family:Arial,Helvetica,sans-serif;max-width:560px;margin:0 auto;padding:16px;color:#1b1f24">
<h2 style="margin:0 0 12px;font-size:18px">${esc(title)}</h2>${inner}${link}
<p style="margin:24px 0 0;font-size:12px;color:#6b7280">You can turn these emails off in Crew Logbook under Roster → Email notifications.</p></div>`;
}

function dutyLine(p: any): string {
  const route = p.origin && p.destination ? `${p.origin}–${p.destination}` : '';
  return [p.duty_date, p.flight || p.duty_type, route, p.std_local].filter(Boolean).join(' · ');
}

export function renderMail(job: Job, appUrl: string): Mail {
  const name = job.to_name ? job.to_name.split(' ')[0] : 'there';
  if (job.kind === 'message') {
    const p = job.items[0] || {};
    const body = esc(p.body).replace(/\n/g, '<br>');
    const ack = p.requires_ack && p.has_account
      ? '<p style="background:#fff7e0;padding:10px;border-radius:6px"><b>Please open Crew Logbook and tap “Acknowledge”</b> so the office knows you have read this.</p>' : '';
    return {
      subject: String(p.subject || 'Message from crew office'),
      html: shell(appUrl, String(p.subject || 'Message'), `<p>Hi ${esc(name)},</p><p>${body}</p>${ack}<p style="color:#6b7280">— ${esc(p.sender_name || 'Crew office')}</p>`),
      text: `Hi ${name},\n\n${p.body}\n\n— ${p.sender_name || 'Crew office'}${p.requires_ack && p.has_account ? '\n\nPlease open Crew Logbook and acknowledge this message.' : ''}${appUrl ? '\n' + appUrl : ''}`,
    };
  }
  if (job.kind === 'leave_decision') {
    const p = job.items[0] || {};
    const what = LEAVE_LABEL[p.kind] || 'Leave';
    const status = p.status === 'approved' ? 'approved' : p.status === 'declined' ? 'declined' : 'cancelled';
    const range = p.from === p.to || !p.to ? p.from : `${p.from} to ${p.to}`;
    const note = p.note ? `<p>Note: ${esc(p.note)}</p>` : '';
    return {
      subject: `${what} ${status}: ${range}`,
      html: shell(appUrl, `${what} ${status}`, `<p>Hi ${esc(name)},</p><p>Your ${esc(what.toLowerCase())} for <b>${esc(range)}</b> has been <b>${esc(status)}</b>.</p>${note}`),
      text: `Hi ${name},\n\nYour ${what.toLowerCase()} for ${range} has been ${status}.${p.note ? '\nNote: ' + p.note : ''}${appUrl ? '\n' + appUrl : ''}`,
    };
  }
  // roster_change digest
  const items = job.items || [];
  const rows = items.map((p) => {
    const label = CHANGE_LABEL[p.change_type] || 'Changed';
    const why = p.reason ? ` <span style="color:#6b7280">(${esc(p.reason)})</span>` : '';
    return `<li style="margin:6px 0"><b>${esc(label)}</b> — ${esc(dutyLine(p))}${why}</li>`;
  }).join('');
  const textRows = items.map((p) => `- ${CHANGE_LABEL[p.change_type] || 'Changed'}: ${dutyLine(p)}${p.reason ? ' (' + p.reason + ')' : ''}`).join('\n');
  return {
    subject: items.length === 1 ? 'Your roster has changed' : `Your roster has changed (${items.length} updates)`,
    html: shell(appUrl, 'Roster update', `<p>Hi ${esc(name)},</p><p>The crew office updated your roster:</p><ul style="padding-left:18px">${rows}</ul>`),
    text: `Hi ${name},\n\nThe crew office updated your roster:\n${textRows}${appUrl ? '\n\n' + appUrl : ''}`,
  };
}

export interface Env {
  SUPABASE_URL?: string; SUPABASE_SERVICE_ROLE_KEY?: string; RESEND_API_KEY?: string;
  EMAIL_FROM?: string; CRON_SECRET?: string; APP_URL?: string;
}

export async function handle(req: Request, env: Env, makeClient: (url: string, key: string) => Promise<any>,
                             fetchImpl: typeof fetch = fetch): Promise<Response> {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return json({ error: 'POST only' }, 405);
  if (!env.CRON_SECRET || req.headers.get('x-cron-secret') !== env.CRON_SECRET) return json({ error: 'Not allowed' }, 401);
  if (!env.RESEND_API_KEY || !env.EMAIL_FROM || !env.SUPABASE_URL || !env.SUPABASE_SERVICE_ROLE_KEY) {
    return json({ error: 'Email is not configured yet (RESEND_API_KEY / EMAIL_FROM missing). Mail stays queued.' }, 503);
  }
  const db = await makeClient(env.SUPABASE_URL, env.SUPABASE_SERVICE_ROLE_KEY);
  const { data: jobs, error } = await db.rpc('email_claim_batch', { p_limit: 25 });
  if (error) return json({ error: 'claim failed: ' + error.message }, 500);

  let sent = 0, retried = 0, failed = 0;
  for (const job of (jobs || []) as Job[]) {
    let state: 'sent' | 'retry' | 'failed' = 'sent', err = '';
    try {
      const mail = renderMail(job, env.APP_URL || '');
      const r = await fetchImpl('https://api.resend.com/emails', {
        method: 'POST',
        headers: { Authorization: `Bearer ${env.RESEND_API_KEY}`, 'Content-Type': 'application/json' },
        body: JSON.stringify({ from: env.EMAIL_FROM, to: [job.to_email], subject: mail.subject, html: mail.html, text: mail.text }),
      });
      if (!r.ok) {
        err = `Resend ${r.status}: ${(await r.text()).slice(0, 300)}`;
        // 4xx (except rate-limit/timeout) will not get better by waiting
        state = r.status >= 400 && r.status < 500 && r.status !== 429 && r.status !== 408 ? 'failed' : 'retry';
      }
    } catch (e) {
      state = 'retry'; err = String((e as Error)?.message || e);
    }
    await db.rpc('email_mark', { p_ids: job.ids, p_state: state, p_error: err || null });
    if (state === 'sent') sent++; else if (state === 'retry') retried++; else failed++;
  }
  return json({ claimed: (jobs || []).length, sent, retried, failed });
}

const D = (globalThis as any).Deno;
if (D?.serve) {
  D.serve((req: Request) => handle(req, D.env.toObject(), async (url, key) => {
    const { createClient } = await import('https://esm.sh/@supabase/supabase-js@2');
    return createClient(url, key, { auth: { persistSession: false } });
  }));
}
