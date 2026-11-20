# send-push

Phone/browser push notifications (roster changes, messages, leave decisions). Works on Android Chrome, desktop browsers, and iPhones **once the app is added to the Home Screen** (iOS 16.4+).

## One-time setup
1. Generate keys (on any computer with Node): `npx web-push generate-vapid-keys`
2. Supabase → Edge Functions → Secrets:
   - `VAPID_PUBLIC_KEY`, `VAPID_PRIVATE_KEY` – from step 1
   - `VAPID_SUBJECT` – `mailto:you@yourdomain.com`
   - `CRON_SECRET` – the same string used for `send-emails`
   - `APP_URL` – `https://crewlogbook.app`
3. Deploy: `supabase functions deploy send-push --no-verify-jwt`
4. Schedule every minute (same pattern as send-emails):

```sql
select cron.schedule('send-push', '* * * * *', $$
  select net.http_post(
    url := 'https://<PROJECT-REF>.supabase.co/functions/v1/send-push',
    headers := jsonb_build_object('x-cron-secret', '<CRON_SECRET>', 'Content-Type', 'application/json'),
    body := '{}'::jsonb);
$$);
```

Crew then turn it on themselves: My Roster → Messages from crew office → Phone notifications.
