# TaskMint — micro-task rewards platform

TaskMint is a React + Supabase application with member and administrator workspaces. It includes real Supabase Auth, PostgreSQL/RLS, private proof uploads, ledger-backed wallet views, task reviews, daily check-in RPC, and withdrawal reservation RPC.

## Important deployment boundary

This repository is the application source and database setup, **not a preconfigured hosted service**. You must create your own Supabase project, apply the SQL, configure Auth/Storage, set environment variables, and deploy to Netlify. No live payment gateway is integrated: plan payments are manually verified by an administrator using the submitted proof. Never treat a screenshot as an automatic payment confirmation.

## Requirements

- Node.js 20+
- Supabase project
- Netlify account (or another static host)

## Local setup

```bash
npm install
cp .env.example .env
# Set VITE_SUPABASE_URL and VITE_SUPABASE_ANON_KEY in .env
npm run dev
```

Build with `npm run build`.

## Supabase setup

1. Create a Supabase project.
2. Open **SQL Editor**, paste and run `supabase/schema.sql`.
3. In **Storage**, create two buckets named `payment-proofs` and `task-proofs`. Set both to **Private**. The SQL file includes object policies that allow a user to upload/read their own folder and administrators to read proofs using signed URLs.
4. In **Authentication → URL Configuration**, set your Site URL and add local and deployed redirect URLs, including `/reset-password`.
5. Enable email confirmations if desired and configure SMTP for reliable production email delivery.
6. Register your own account through the app. Then, in SQL Editor, promote that account:
   ```sql
   update public.profiles set role = 'admin' where email = 'you@example.com';
   ```
   There is deliberately no public admin registration.
7. In Admin console → Settings, configure daily reward, withdrawal limits, payment instructions, contact email, and referral reward.

## Environment variables

Set these in `.env` locally and in Netlify Site configuration → Environment variables:

- `VITE_SUPABASE_URL`: Supabase project URL
- `VITE_SUPABASE_ANON_KEY`: Supabase publishable/anon key

The anon key is intended for browser use and is protected by RLS. **Never set or expose the `service_role` key in a `VITE_` variable or frontend bundle.**

## Netlify deployment

1. Push this folder to a Git repository.
2. In Netlify, import the repository.
3. Build command: `npm run build`
4. Publish directory: `dist`
5. Add the two environment variables above.
6. Deploy, then add the Netlify production URL to Supabase Auth redirect URLs.

`netlify.toml` includes the SPA fallback route.

## Included features

- Email/password sign-up, sign-in, sign-out, password reset
- Protected member routes and admin route guarded by database role
- Dashboard and wallet data fetched from Supabase
- Plan request with private proof upload and pending review
- Task listing and one submission per user/task
- Admin review RPC for purchases and task submissions
- Daily check-in RPC with unique per-user/day constraint
- Withdrawal request with atomic balance reservation and admin approve/reject/pay actions
- Referral code and referral tracking table
- Admin user, plan, task, request and settings views
- Responsive desktop sidebar and mobile layout

## Current implementation notes / production hardening

- The admin console uses SQL security-definer RPCs for sensitive review and suspension actions. The browser cannot assign itself an admin role.
- Wallet balances are read-only to clients. Only trusted database functions update balances.
- Task submission uniqueness prevents duplicate submissions and rewards are credited only on the first valid admin approval.
- Withdrawal funds are reserved in a database trigger. Rejection refunds the reserve; marking approved requests paid finalizes the withdrawal.
- The referral code is generated and referral attribution is recorded when the account metadata contains `referral_code`. The registration form currently does not yet parse `?ref=` into metadata; wire this in before public referral campaigns.
- Plan approval currently marks the purchase approved and records activation, but a separate entitlement table / plan-access enforcement should be added before plans are used to gate paid task content.
- Password reset requires Supabase Auth email delivery and correct redirect configuration.
- No real eSewa API integration is present. Admins manually reconcile payouts and store a transaction reference.
- The admin settings page includes the core reward/payment settings; visual theme/logo/contact display customization can be extended as needed.
- No automated browser/e2e test suite is included. Run the test checklist below against a staging Supabase project before accepting real users or money.

## Staging acceptance checklist

- [ ] Register a new account and confirm email (if enabled)
- [ ] Sign in, refresh, sign out
- [ ] Request and complete password reset
- [ ] Verify dashboard reads empty/live database values
- [ ] Create a plan request and upload proof
- [ ] Confirm private proof cannot be accessed by another member
- [ ] Promote a staging admin and approve/reject a purchase
- [ ] Create a task, submit once, and approve/reject it
- [ ] Attempt duplicate task submission (must fail)
- [ ] Claim daily check-in twice on the same day (second must fail)
- [ ] Confirm wallet ledger and balances update together
- [ ] Request withdrawal with enough balance; verify reserve
- [ ] Attempt overdraw / duplicate withdrawal (must fail)
- [ ] Reject withdrawal and verify refund; approve then mark paid
- [ ] Verify referral attribution and eligibility rules before enabling rewards
- [ ] Test mobile navigation and layout on Android/iOS
- [ ] Verify non-admin cannot call admin RPCs or access admin data
- [ ] Verify storage buckets are private and signed URLs expire

## Uploaded bank QR / brand asset

The provided image is included as `public/bank-payment-reference.jpg`. It is a supplied payment reference image only; confirm the bank/account details and payment instructions with the account owner before publishing it. The application currently shows administrator-configured text instructions rather than automatically treating the QR image as proof of payment.