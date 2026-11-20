// roster-ics — a private, always-up-to-date calendar feed of one crew member's roster.
// URL: https://<project>.supabase.co/functions/v1/roster-ics?t=<secret token>
// Deploy with --no-verify-jwt (calendar apps cannot sign in); the secret token is the key.

const CORS = { 'Access-Control-Allow-Origin': '*' };

export interface DutyRow {
  duty_id: string; duty_date: string; duty_type?: string | null; flight_number?: string | null;
  origin?: string | null; destination?: string | null; std_local?: string | null; std_utc?: string | null;
  sta_local?: string | null; sta_utc?: string | null; remark?: string | null; status?: string | null;
  updated_at?: string | null;
}

const hm = (s?: string | null): number | null => {
  const m = /^(\d{1,2}):(\d{2})/.exec(s || ''); if (!m) return null;
  const v = +m[1] * 60 + +m[2]; return v < 1440 ? v : null;
};
const pad = (n: number) => String(n).padStart(2, '0');
const utcStamp = (ms: number) => { const d = new Date(ms); return `${d.getUTCFullYear()}${pad(d.getUTCMonth() + 1)}${pad(d.getUTCDate())}T${pad(d.getUTCHours())}${pad(d.getUTCMinutes())}00Z`; };
const dateStamp = (ms: number) => { const d = new Date(ms); return `${d.getUTCFullYear()}${pad(d.getUTCMonth() + 1)}${pad(d.getUTCDate())}`; };
const floatStamp = (ms: number) => utcStamp(ms).replace('Z', '');

const TYPE_LABEL: Record<string, string> = {
  WOFF: 'Weekly off', DMA: 'Duty may be assigned', NA: 'Not available', SBY: 'Standby', TRG: 'Training',
  GRD: 'Ground duty', SICK: 'Sick', LEAVE: 'Leave', LAYOVER: 'Layover',
};

export function esc(s: string): string {
  return s.replace(/\\/g, '\\\\').replace(/;/g, '\;').replace(/,/g, '\\,').replace(/\r?\n/g, '\\n');
}
export function fold(line: string): string {
  const enc = new TextEncoder(); if (enc.encode(line).length <= 75) return line;
  const out: string[] = []; let cur = '', bytes = 0;
  for (const ch of line) {
    const b = enc.encode(ch).length;
    if (bytes + b > (out.length ? 74 : 75)) { out.push(cur); cur = ch; bytes = b; } else { cur += ch; bytes += b; }
  }
  out.push(cur); return out.join('\r\n ');
}

/** One VEVENT (array of lines) for a duty. Timed duties use UTC when both local and UTC times are known. */
export function dutyEvent(d: DutyRow): string[] {
  const [y, m, day] = d.duty_date.split('-').map(Number);
  const dayMs = Date.UTC(y, m - 1, day);
  const type = (d.duty_type || '').toUpperCase();
  const route = d.origin && d.destination ? `${d.origin}–${d.destination}` : '';
  const isFlight = !!d.flight_number || type.startsWith('OP');
  const label = isFlight ? `✈ ${[d.flight_number, route].filter(Boolean).join(' ') || 'Flight'}`
    : (TYPE_LABEL[type] || (type.includes('LAYOVER') ? 'Layover' : d.duty_type || 'Duty'));
  const cancelled = (d.status || '') === 'cancelled';
  const stamp = d.updated_at ? utcStamp(Date.parse(d.updated_at)) : utcStamp(Date.now());
  const L = ['BEGIN:VEVENT', `UID:${d.duty_id}@crewlogbook.app`, `DTSTAMP:${stamp}`, `LAST-MODIFIED:${stamp}`];

  const sl = hm(d.std_local), su = hm(d.std_utc), al = hm(d.sta_local), au = hm(d.sta_utc);
  let hasTime = false;
  if (sl !== null && isFlight || (sl !== null && !TYPE_LABEL[type])) {
    hasTime = true;
    if (su !== null) {
      const off = ((sl - su + 1440 + 720) % 1440) - 720;           // local minus UTC, in minutes
      const start = dayMs + sl * 60000 - off * 60000;
      let durMin = 60;
      if (au !== null) { durMin = (au - su + 1440) % 1440 || 60; }
      else if (al !== null) { durMin = (al - sl + 1440) % 1440 || 60; }
      L.push(`DTSTART:${utcStamp(start)}`, `DTEND:${utcStamp(start + durMin * 60000)}`);
    } else {
      const start = dayMs + sl * 60000;
      const durMin = al !== null ? ((al - sl + 1440) % 1440 || 60) : 60;
      L.push(`DTSTART:${floatStamp(start)}`, `DTEND:${floatStamp(start + durMin * 60000)}`);
    }
  }
  if (!hasTime) L.push(`DTSTART;VALUE=DATE:${dateStamp(dayMs)}`, `DTEND;VALUE=DATE:${dateStamp(dayMs + 86400000)}`);
  L.push(`SUMMARY:${esc((cancelled ? 'CANCELLED ' : '') + label)}`);
  const desc = [d.duty_type ? `Duty: ${d.duty_type}` : '', d.remark || '', d.status && d.status !== 'rostered' ? `Status: ${d.status}` : ''].filter(Boolean).join('\n');
  if (desc) L.push(`DESCRIPTION:${esc(desc)}`);
  if (d.origin) L.push(`LOCATION:${esc(d.origin)}`);
  L.push('TRANSP:' + (isFlight || type === 'TRG' || type === 'GRD' || type === 'SBY' ? 'OPAQUE' : 'TRANSPARENT'));
  if (cancelled) L.push('STATUS:CANCELLED');
  else if (isFlight && hasTime) L.push('BEGIN:VALARM', 'ACTION:DISPLAY', `DESCRIPTION:${esc(label)}`, 'TRIGGER:-PT2H', 'END:VALARM');
  L.push('END:VEVENT');
  return L;
}

export function buildIcs(rows: DutyRow[], name: string): string {
  const L = ['BEGIN:VCALENDAR', 'VERSION:2.0', 'PRODID:-//Crew Logbook//Roster//EN', 'CALSCALE:GREGORIAN', 'METHOD:PUBLISH',
    `X-WR-CALNAME:${esc('Crew roster' + (name ? ' – ' + name : ''))}`, 'REFRESH-INTERVAL;VALUE=DURATION:PT1H', 'X-PUBLISHED-TTL:PT1H'];
  for (const r of rows) L.push(...dutyEvent(r));
  L.push('END:VCALENDAR');
  return L.map(fold).join('\r\n') + '\r\n';
}

export async function handle(req: Request, makeClient: () => Promise<any>): Promise<Response> {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'GET' && req.method !== 'HEAD') return new Response('GET only', { status: 405, headers: CORS });
  const t = new URL(req.url).searchParams.get('t') || '';
  if (!/^[A-Za-z0-9_-]{20,128}$/.test(t)) return new Response('Not found', { status: 404, headers: CORS });
  const db = await makeClient();
  const { data, error } = await db.rpc('cal_feed', { p_token: t });
  if (error) return new Response('Error', { status: 500, headers: CORS });
  if (!data || !data.length) {
    // Unknown token and empty roster look the same on purpose
    return new Response(buildIcs([], ''), { status: 200, headers: { ...CORS, 'Content-Type': 'text/calendar; charset=utf-8' } });
  }
  const ics = buildIcs(data as DutyRow[], (data[0] as any).crew_name || '');
  return new Response(req.method === 'HEAD' ? null : ics, {
    status: 200, headers: { ...CORS, 'Content-Type': 'text/calendar; charset=utf-8', 'Cache-Control': 'private, max-age=300',
      'Content-Disposition': 'inline; filename="roster.ics"' },
  });
}

const D = (globalThis as any).Deno;
if (D?.serve) {
  D.serve((req: Request) => handle(req, async () => {
    const { createClient } = await import('https://esm.sh/@supabase/supabase-js@2');
    return createClient(D.env.get('SUPABASE_URL'), D.env.get('SUPABASE_SERVICE_ROLE_KEY'), { auth: { persistSession: false } });
  }));
}
