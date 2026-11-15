// =============================================================================
// Edge Function: admin-create-staff
//
// Lets an administrator create staff accounts (roster officer, check-in agent,
// ops manager) and reset their temporary password. Creating an auth user needs
// the service-role key, which must never reach the browser — hence this
// function. Every call is checked against the caller's profile: only an
// admin of the same airline can use it.
//
// Body (JSON, POST):
//   { "action": "create", "full_name": "...", "email": "...", "phone": "...",
//     "password": "temporary password (min 8)", "role": "roster_officer" | "check_in_agent" | "ops_manager" }
//   { "action": "reset_password", "user_id": "...", "password": "new temporary password" }
//
// Deploy: Supabase Dashboard → Edge Functions → Create function
//   name: admin-create-staff, paste this file, Deploy.
//   (SUPABASE_URL, SUPABASE_ANON_KEY and SUPABASE_SERVICE_ROLE_KEY are
//   provided to the function automatically.) Or: supabase functions deploy admin-create-staff
// =============================================================================

export const STAFF_ROLES = ['roster_officer', 'check_in_agent', 'ops_manager'] as const;

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

function json(status: number, body: Record<string, unknown>): Response {
  return new Response(JSON.stringify(body), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });
}

export type Env = { url: string; anonKey: string; serviceKey: string };
// deno-lint-ignore no-explicit-any
export type MakeClient = (url: string, key: string, opts?: any) => any;

export function validateCreate(b: Record<string, unknown>): string | null {
  const name = String(b.full_name ?? '').trim();
  const email = String(b.email ?? '').trim();
  const phone = String(b.phone ?? '').trim();
  const pw = String(b.password ?? '');
  if (name.length < 2 || name.length > 80) return 'Enter the full name (2–80 characters).';
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email) || email.length > 120) return 'Enter a valid email address.';
  if (phone && !/^[0-9+()\-\s]{7,20}$/.test(phone)) return 'Enter a valid phone number.';
  if (pw.length < 8 || pw.length > 72) return 'The temporary password must be 8–72 characters.';
  if (!(STAFF_ROLES as readonly string[]).includes(String(b.role))) return 'Choose a valid staff role.';
  return null;
}

// Audit trail (migration 26). Never lets a logging problem fail the request.
async function audit(admin: any, me: any, action: string, targetId: string, label: string, details: Record<string, unknown>) {
  try {
    await admin.from('admin_audit_log').insert({
      tenant_id: me.tenant_id, actor_id: me.id, actor_name: me.full_name ?? null,
      action, target_id: targetId, target_label: label, details,
    });
  } catch { /* table may not exist yet */ }
}

export async function handle(req: Request, env: Env, makeClient: MakeClient): Promise<Response> {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return json(405, { error: 'POST only.' });

  const auth = req.headers.get('Authorization') ?? '';
  if (!auth.startsWith('Bearer ')) return json(401, { error: 'Sign in first.' });

  // Who is calling?
  const userClient = makeClient(env.url, env.anonKey, { global: { headers: { Authorization: auth } } });
  const { data: u, error: uErr } = await userClient.auth.getUser();
  if (uErr || !u?.user) return json(401, { error: 'Your session has expired. Sign in again.' });

  const admin = makeClient(env.url, env.serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });
  const { data: me } = await admin.from('profiles')
    .select('id, full_name, is_admin, role, blocked, tenant_id').eq('id', u.user.id).maybeSingle();
  const isAdmin = !!me && (me.is_admin === true || me.role === 'admin') && me.blocked !== true;
  if (!isAdmin) return json(403, { error: 'Administrators only.' });
  if (!me.tenant_id) return json(400, { error: 'Your account has no airline assigned.' });

  let body: Record<string, unknown>;
  try { body = await req.json(); } catch { return json(400, { error: 'Invalid request.' }); }

  // ── Create ───────────────────────────────────────────────
  if (body.action === 'create') {
    const bad = validateCreate(body);
    if (bad) return json(400, { error: bad });
    const email = String(body.email).trim().toLowerCase();
    const fullName = String(body.full_name).trim();
    const phone = String(body.phone ?? '').trim() || null;
    const role = String(body.role);

    const { data: created, error: cErr } = await admin.auth.admin.createUser({
      email, password: String(body.password), email_confirm: true,
      user_metadata: { full_name: fullName },
    });
    if (cErr || !created?.user) {
      const dup = /already|registered|exists/i.test(cErr?.message ?? '');
      return json(dup ? 409 : 400, { error: dup ? 'An account with this email already exists.' : (cErr?.message ?? 'Could not create the account.') });
    }

    const { error: pErr } = await admin.from('profiles').upsert({
      id: created.user.id, email, full_name: fullName, phone, role,
      tenant_id: me.tenant_id, user_class: 'airline',
      must_change_password: true, created_by: me.id, blocked: false,
    }, { onConflict: 'id' });
    if (pErr) {
      await admin.auth.admin.deleteUser(created.user.id);          // no half-created accounts
      return json(500, { error: 'Could not save the profile: ' + pErr.message });
    }
    await audit(admin, me, 'staff_created', created.user.id, fullName || email, { role });
    return json(200, { ok: true, user: { id: created.user.id, email, full_name: fullName, role } });
  }

  // ── Reset temporary password ─────────────────────────────
  if (body.action === 'reset_password') {
    const pw = String(body.password ?? '');
    if (pw.length < 8 || pw.length > 72) return json(400, { error: 'The temporary password must be 8–72 characters.' });
    const { data: target } = await admin.from('profiles')
      .select('id, role, tenant_id').eq('id', String(body.user_id ?? '')).maybeSingle();
    if (!target || target.tenant_id !== me.tenant_id || !(STAFF_ROLES as readonly string[]).includes(target.role)) {
      return json(404, { error: 'Staff account not found.' });
    }
    const { error: rErr } = await admin.auth.admin.updateUserById(target.id, { password: pw });
    if (rErr) return json(400, { error: rErr.message });
    await admin.from('profiles').update({ must_change_password: true }).eq('id', target.id);
    await audit(admin, me, 'staff_password_reset', target.id, String(body.user_id), {});
    return json(200, { ok: true });
  }

  return json(400, { error: 'Unknown action.' });
}

// Start the server on Supabase (Deno). Skipped when imported by a test.
// deno-lint-ignore no-explicit-any
const D = (globalThis as any).Deno;
if (D?.serve) {
  const { createClient } = await import('https://esm.sh/@supabase/supabase-js@2');
  D.serve((req: Request) => handle(req, {
    url: D.env.get('SUPABASE_URL')!,
    anonKey: D.env.get('SUPABASE_ANON_KEY')!,
    serviceKey: D.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
  }, createClient));
}
