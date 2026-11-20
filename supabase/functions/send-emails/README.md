# send-emails

Delivers queued crew emails (roster changes, messages from the crew office, leave decisions).

## One-time setup
1. Create a [Resend](https://resend.com) account, add and verify your sending domain (SPF + DKIM records), create an API key.
2. Supabase → Edge Functions → Secrets:
   - `RESEND_API_KEY` – the key
   - `EMAIL_FROM` – e.g. `Crew Logbook <crew@yourdomain.com>` (must be on the verified domain)
   - `CRON_SECRET` – any long random string
   - `APP_URL` – `https://crewlogbook.app`
3. Deploy: `supabase functions deploy send-emails --no-verify-jwt`
4. Schedule it every minute (SQL editor; enable `pg_cron` and `pg_net` under Database → Extensions first):

```sql
select cron.schedule('send-emails', '* * * * *', $$
  select net.http_post(
    url := 'https://<PROJECT-REF>.supabase.co/functions/v1/send-emails',
    headers := jsonb_build_object('x-cron-secret', '<CRON_SECRET>', 'Content-Type', 'application/json'),
    body := '{}'::jsonb);
$$);
```

Until this is set up nothing is lost: emails wait in `email_queue`. Failed sends retry up to 3 times, then show as failed in the message history.
