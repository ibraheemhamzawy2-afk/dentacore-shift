# DentaCore Shift

Arabic-first (RTL) PWA that connects dentists with licensed dental clinics:

- **Shifts** — doctors book a clinic chair for a shift (fixed price or revenue split).
- **Annual rentals** — clinic owners list a whole clinic for a 12-month+ lease; all contact goes through the platform team until signing.
- **Direct long-term dealing** — a one-time introduction fee when a clinic wants to work with a doctor outside the platform.

Live (pilot): https://dentacoreshift.pages.dev

## Stack

| Layer | What |
| --- | --- |
| Frontend | Single `site/index.html` — vanilla JS SPA, hash routing, no build step. `supabase-js` 2.118.0 (UMD, jsDelivr). |
| Hosting | Cloudflare Pages (direct upload of `site/`). `site/_headers` sets CSP + security headers. |
| Backend | Supabase: Postgres + RLS, Auth (email/password), Storage (`docs` private, `media` public), `pg_cron`. |
| Payments | Manual InstaPay / wallet transfers. User uploads proof + reference; admin approves in the admin panel. |
| Verification | Documents are sent over WhatsApp (button with prefilled message); admin verifies in the panel. |

## Repo layout

```
site/                       deployable static site (upload this folder to Cloudflare Pages)
  index.html                the whole app (UI, routing, legal pages, admin panel)
  sw.js                     network-first service worker
  manifest.webmanifest, icons, _headers
supabase/
  01_setup.sql              schema, enums, RLS, triggers, RPCs, storage policies, cron
  02_rentals.sql            annual clinic rentals: rentals, rental_private, rental_leads + RPCs
  03_direct_dealing.sql     introduction-fee quote (hire_quote / request_hire)
```

Run the SQL files in order in Supabase SQL Editor. All three are idempotent.

## Security model (please review)

- Only the **publishable (anon) key** is in the client. No service-role key anywhere.
- All business rules live in Postgres: `security definer` RPCs (`book_shift`, `submit_payment`, `admin_review_payment`, `cancel_booking`, `finish_shift`, `calc_fee`, `request_rental`, `admin_sign_rental`, …) with `set search_path = public`.
- RLS on every table; `anon` has no table access. Cross-table checks use helper functions (`can_see_booking`, `clinic_knows_doctor`, …) to avoid policy recursion.
- Guard triggers (`guard_profile`, `guard_verify`, `guard_shift`, `guard_rental`) stop users from changing role, verification status, prices of booked shifts, or listing status.
- Contact details / exact addresses (`contacts`, `clinic_private`, `rental_private`) are only readable by the owner, the admin, and (for shifts) the booked doctor shortly before the shift.
- Storage: private `docs` bucket with per-user folders (`{uid}/…`), signed URLs for admin; public `media` bucket for clinic photos.
- Admin = `profiles.role = 'admin'`, set manually in SQL.

## Things worth checking before launch

1. RLS / RPC review — any path for a user to read another user's contacts, docs, or payment proofs, or to change amounts/statuses.
2. Fee math in `calc_fee` (monthly cap per doctor–clinic pair) and settlement flow for revenue-split shifts.
3. Booking holds and `expire_holds` cron; race conditions when two doctors book the same shift.
4. CSP in `_headers` and XSS: all user content goes through `esc()` before `innerHTML`.
5. Mobile UX on small Android phones; PWA install + service worker update behaviour.
6. Supabase Auth settings: Site URL / redirect URLs, rate limits, email confirmation (currently off for the pilot).
7. Moving to a custom domain (`shift.<domain>`) and Supabase Pro (backups, no pausing) before real payments.

## Local preview

No build needed: `npx serve site` (or any static server) and open the URL. It talks to the live Supabase project, so use test accounts.
