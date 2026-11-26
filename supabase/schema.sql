-- TaskMint database schema. Run in Supabase SQL Editor as project owner.
create extension if not exists pgcrypto;

create type public.app_role as enum ('member','admin');
create type public.request_status as enum ('pending','approved','rejected','paid');
create type public.submission_status as enum ('submitted','under_review','approved','rejected');

create table public.profiles (
 id uuid primary key references auth.users(id) on delete cascade,
 full_name text not null default '',
 email text not null default '',
 role public.app_role not null default 'member',
 referral_code text unique not null default upper(substr(encode(gen_random_bytes(8),'hex'),1,10)),
 referred_by uuid references public.profiles(id),
 is_suspended boolean not null default false,
 created_at timestamptz not null default now()
);
create table public.plans (
 id uuid primary key default gen_random_uuid(), name text not null, price numeric(12,2) not null check(price>=0),
 description text not null default '', benefits jsonb not null default '[]'::jsonb, task_count integer not null default 0 check(task_count>=0),
 is_active boolean not null default true, created_at timestamptz not null default now()
);
create table public.purchases (
 id uuid primary key default gen_random_uuid(), user_id uuid not null default auth.uid() references public.profiles(id),
 plan_id uuid not null references public.plans(id), payment_proof_path text, status public.request_status not null default 'pending',
 admin_note text, created_at timestamptz not null default now(), reviewed_at timestamptz
);
create table public.payment_proofs (
 id uuid primary key default gen_random_uuid(), purchase_id uuid not null references public.purchases(id) on delete cascade,
 storage_path text not null, created_at timestamptz not null default now()
);
create table public.tasks (
 id uuid primary key default gen_random_uuid(), title text not null, description text not null, instructions text not null default '',
 reward numeric(12,2) not null check(reward>=0), category text not null default 'General',
 proof_required boolean not null default true, is_active boolean not null default true, created_at timestamptz not null default now()
);
create table public.task_submissions (
 id uuid primary key default gen_random_uuid(), user_id uuid not null default auth.uid() references public.profiles(id),
 task_id uuid not null references public.tasks(id), proof_path text, status public.submission_status not null default 'submitted',
 admin_note text, created_at timestamptz not null default now(), reviewed_at timestamptz,
 unique(user_id,task_id)
);
create table public.wallets (
 user_id uuid primary key references public.profiles(id) on delete cascade,
 available_balance numeric(14,2) not null default 0 check(available_balance>=0),
 pending_balance numeric(14,2) not null default 0 check(pending_balance>=0),
 total_earned numeric(14,2) not null default 0 check(total_earned>=0),
 total_withdrawn numeric(14,2) not null default 0 check(total_withdrawn>=0),
 updated_at timestamptz not null default now()
);
create table public.transactions (
 id uuid primary key default gen_random_uuid(), user_id uuid not null references public.profiles(id),
 amount numeric(14,2) not null, type text not null, description text not null, status text not null default 'approved',
 reference_id uuid, created_at timestamptz not null default now()
);
create table public.daily_checkins (
 id uuid primary key default gen_random_uuid(), user_id uuid not null default auth.uid() references public.profiles(id),
 checkin_date date not null default (now() at time zone 'Asia/Kathmandu')::date,
 reward_amount numeric(12,2) not null check(reward_amount>=0), created_at timestamptz not null default now(),
 unique(user_id,checkin_date)
);
create table public.referrals (
 id uuid primary key default gen_random_uuid(), referrer_id uuid not null references public.profiles(id),
 referred_user_id uuid not null unique references public.profiles(id), status text not null default 'pending',
 reward_amount numeric(12,2) not null default 0, created_at timestamptz not null default now()
);
create table public.withdrawal_requests (
 id uuid primary key default gen_random_uuid(), user_id uuid not null default auth.uid() references public.profiles(id),
 amount numeric(14,2) not null check(amount>0), payment_method text not null, account_holder text not null,
 account_details text not null, status public.request_status not null default 'pending', admin_note text,
 transaction_reference text, created_at timestamptz not null default now(), reviewed_at timestamptz
);
create table public.admin_settings (
 id integer primary key default 1 check(id=1), website_name text not null default 'TaskMint',
 daily_reward numeric(12,2) not null default 5 check(daily_reward>=0), referral_reward numeric(12,2) not null default 0 check(referral_reward>=0),
 min_withdrawal numeric(12,2) not null default 100 check(min_withdrawal>0), max_withdrawal numeric(12,2) not null default 10000 check(max_withdrawal>=min_withdrawal),
 payment_instructions text not null default 'Contact support for payment instructions.',
 contact_email text not null default '', updated_at timestamptz not null default now()
);
create table public.admin_audit_logs (
 id uuid primary key default gen_random_uuid(), admin_id uuid not null references public.profiles(id),
 action text not null, entity_type text not null, entity_id uuid, details jsonb not null default '{}'::jsonb,
 created_at timestamptz not null default now()
);

create index purchases_user_idx on public.purchases(user_id,created_at desc);
create index task_submissions_user_idx on public.task_submissions(user_id,created_at desc);
create index transactions_user_idx on public.transactions(user_id,created_at desc);
create index withdrawals_user_idx on public.withdrawal_requests(user_id,created_at desc);
create index referrals_referrer_idx on public.referrals(referrer_id,created_at desc);

create or replace function public.is_admin() returns boolean language sql stable security definer set search_path=public as $$
 select exists(select 1 from public.profiles where id=auth.uid() and role='admin' and not is_suspended)
$$;
revoke all on function public.is_admin() from public;
grant execute on function public.is_admin() to authenticated;

-- Profile and wallet are created from trusted auth metadata; role is never accepted from client.
create or replace function public.handle_new_user() returns trigger language plpgsql security definer set search_path=public as $$
declare v_ref text; v_referrer uuid;
begin
 v_ref := nullif(new.raw_user_meta_data->>'referral_code','');
 if v_ref is not null then select id into v_referrer from public.profiles where referral_code=upper(v_ref); end if;
 insert into public.profiles(id,full_name,email,referred_by) values(new.id,coalesce(new.raw_user_meta_data->>'full_name',''),new.email,v_referrer);
 insert into public.wallets(user_id) values(new.id);
 if v_referrer is not null then insert into public.referrals(referrer_id,referred_user_id) values(v_referrer,new.id); end if;
 return new;
end $$;
create trigger on_auth_user_created after insert on auth.users for each row execute procedure public.handle_new_user();
insert into public.admin_settings(id) values(1) on conflict do nothing;

-- Atomic daily check-in. A unique constraint prevents duplicate claims across concurrent requests.
create or replace function public.claim_daily_checkin() returns void language plpgsql security definer set search_path=public as $$
declare v_reward numeric;
begin
 if auth.uid() is null then raise exception 'Authentication required'; end if;
 if exists(select 1 from public.profiles where id=auth.uid() and is_suspended) then raise exception 'Account suspended'; end if;
 select daily_reward into v_reward from public.admin_settings where id=1;
 insert into public.daily_checkins(user_id,checkin_date,reward_amount) values(auth.uid(),(now() at time zone 'Asia/Kathmandu')::date,v_reward);
 update public.wallets set available_balance=available_balance+v_reward,total_earned=total_earned+v_reward,updated_at=now() where user_id=auth.uid();
 insert into public.transactions(user_id,amount,type,description,status) values(auth.uid(),v_reward,'daily_checkin','Daily check-in reward','approved');
end $$;
grant execute on function public.claim_daily_checkin() to authenticated;

-- Withdrawal reservation is atomic; funds are debited immediately and returned only on rejection.
create or replace function public.reserve_withdrawal() returns trigger language plpgsql security definer set search_path=public as $$
declare v_min numeric; v_max numeric;
begin
 if auth.uid() is null or new.user_id<>auth.uid() then raise exception 'Not authorized'; end if;
 if exists(select 1 from public.profiles where id=new.user_id and is_suspended) then raise exception 'Account suspended'; end if;
 select min_withdrawal,max_withdrawal into v_min,v_max from public.admin_settings where id=1;
 if new.amount<v_min or new.amount>v_max then raise exception 'Amount outside configured withdrawal limits'; end if;
 update public.wallets set available_balance=available_balance-new.amount,pending_balance=pending_balance+new.amount,updated_at=now()
 where user_id=new.user_id and available_balance>=new.amount;
 if not found then raise exception 'Insufficient available balance'; end if;
 insert into public.transactions(user_id,amount,type,description,status,reference_id) values(new.user_id,-new.amount,'withdrawal_reserve','Withdrawal request reserved','pending',new.id);
 return new;
end $$;
create trigger before_withdrawal_insert before insert on public.withdrawal_requests for each row execute function public.reserve_withdrawal();

create or replace function public.admin_review_purchase(p_purchase_id uuid,p_status text,p_note text default null) returns void language plpgsql security definer set search_path=public as $$
declare r public.purchases;
begin
 if not public.is_admin() then raise exception 'Admin access required'; end if;
 if p_status not in ('approved','rejected') then raise exception 'Invalid status'; end if;
 select * into r from public.purchases where id=p_purchase_id for update;
 if not found or r.status<>'pending' then raise exception 'Purchase is not pending'; end if;
 update public.purchases set status=p_status,admin_note=p_note,reviewed_at=now() where id=p_purchase_id;
 if p_status='approved' then
  insert into public.transactions(user_id,amount,type,description,status,reference_id) values(r.user_id,0,'plan_activation','Plan purchase approved','approved',r.id);
 end if;
 insert into public.admin_audit_logs(admin_id,action,entity_type,entity_id,details) values(auth.uid(),'review_purchase','purchase',r.id,jsonb_build_object('status',p_status,'note',p_note));
end $$;
create or replace function public.admin_review_task_submission(p_submission_id uuid,p_status text,p_note text default null) returns void language plpgsql security definer set search_path=public as $$
declare r public.task_submissions; v_reward numeric;
begin
 if not public.is_admin() then raise exception 'Admin access required'; end if;
 if p_status not in ('approved','rejected') then raise exception 'Invalid status'; end if;
 select * into r from public.task_submissions where id=p_submission_id for update;
 if not found or r.status not in ('submitted','under_review') then raise exception 'Submission is not awaiting review'; end if;
 select reward into v_reward from public.tasks where id=r.task_id;
 update public.task_submissions set status=p_status,admin_note=p_note,reviewed_at=now() where id=r.id;
 if p_status='approved' then
  update public.wallets set available_balance=available_balance+v_reward,total_earned=total_earned+v_reward,updated_at=now() where user_id=r.user_id;
  insert into public.transactions(user_id,amount,type,description,status,reference_id) values(r.user_id,v_reward,'task_reward','Approved task reward','approved',r.id);
 end if;
 insert into public.admin_audit_logs(admin_id,action,entity_type,entity_id,details) values(auth.uid(),'review_task','task_submission',r.id,jsonb_build_object('status',p_status,'reward',v_reward,'note',p_note));
end $$;
create or replace function public.admin_review_withdrawal(p_withdrawal_id uuid,p_status text,p_note text default null,p_reference text default null) returns void language plpgsql security definer set search_path=public as $$
declare r public.withdrawal_requests;
begin
 if not public.is_admin() then raise exception 'Admin access required'; end if;
 if p_status not in ('approved','rejected','paid') then raise exception 'Invalid status'; end if;
 select * into r from public.withdrawal_requests where id=p_withdrawal_id for update;
 if not found then raise exception 'Request not found'; end if;
 if p_status='rejected' then
  if r.status not in ('pending','approved') then raise exception 'Request cannot be rejected'; end if;
  update public.wallets set available_balance=available_balance+r.amount,pending_balance=pending_balance-r.amount,updated_at=now() where user_id=r.user_id;
 elsif p_status='approved' then
  if r.status<>'pending' then raise exception 'Request is not pending'; end if;
 elsif p_status='paid' then
  if r.status<>'approved' then raise exception 'Only approved requests can be marked paid'; end if;
  update public.wallets set pending_balance=pending_balance-r.amount,total_withdrawn=total_withdrawn+r.amount,updated_at=now() where user_id=r.user_id;
 end if;
 update public.withdrawal_requests set status=p_status,admin_note=p_note,transaction_reference=coalesce(p_reference,transaction_reference),reviewed_at=now() where id=r.id;
 insert into public.transactions(user_id,amount,type,description,status,reference_id) values(r.user_id,case when p_status='paid' then -r.amount else 0 end,'withdrawal_'||p_status,'Withdrawal '||p_status,p_status,r.id);
 insert into public.admin_audit_logs(admin_id,action,entity_type,entity_id,details) values(auth.uid(),'review_withdrawal','withdrawal',r.id,jsonb_build_object('status',p_status,'note',p_note,'reference',p_reference));
end $$;
create or replace function public.admin_set_user_suspended(p_user_id uuid,p_suspended boolean) returns void language plpgsql security definer set search_path=public as $$
begin
 if not public.is_admin() then raise exception 'Admin access required'; end if;
 update public.profiles set is_suspended=p_suspended where id=p_user_id and role<>'admin';
 insert into public.admin_audit_logs(admin_id,action,entity_type,entity_id,details) values(auth.uid(),'set_user_suspended','profile',p_user_id,jsonb_build_object('suspended',p_suspended));
end $$;
grant execute on function public.admin_review_purchase(uuid,text,text),public.admin_review_task_submission(uuid,text,text),public.admin_review_withdrawal(uuid,text,text,text),public.admin_set_user_suspended(uuid,boolean) to authenticated;

-- Row-level security
alter table public.profiles enable row level security;
alter table public.plans enable row level security;
alter table public.purchases enable row level security;
alter table public.payment_proofs enable row level security;
alter table public.tasks enable row level security;
alter table public.task_submissions enable row level security;
alter table public.wallets enable row level security;
alter table public.transactions enable row level security;
alter table public.daily_checkins enable row level security;
alter table public.referrals enable row level security;
alter table public.withdrawal_requests enable row level security;
alter table public.admin_settings enable row level security;
alter table public.admin_audit_logs enable row level security;

create policy "profile own or admin read" on public.profiles for select to authenticated using(id=auth.uid() or public.is_admin());
create policy "profile own update limited" on public.profiles for update to authenticated using(id=auth.uid()) with check(id=auth.uid() and role='member' and is_suspended=false);
create policy "plans visible" on public.plans for select to authenticated using(is_active or public.is_admin());
create policy "plans admin manage" on public.plans for all to authenticated using(public.is_admin()) with check(public.is_admin());
create policy "purchases own read" on public.purchases for select to authenticated using(user_id=auth.uid() or public.is_admin());
create policy "purchases own insert" on public.purchases for insert to authenticated with check(user_id=auth.uid() and status='pending');
create policy "purchases admin update" on public.purchases for update to authenticated using(public.is_admin()) with check(public.is_admin());
create policy "proofs admin read" on public.payment_proofs for select to authenticated using(public.is_admin());
create policy "tasks visible" on public.tasks for select to authenticated using(is_active or public.is_admin());
create policy "tasks admin manage" on public.tasks for all to authenticated using(public.is_admin()) with check(public.is_admin());
create policy "submissions own read" on public.task_submissions for select to authenticated using(user_id=auth.uid() or public.is_admin());
create policy "submissions own insert" on public.task_submissions for insert to authenticated with check(user_id=auth.uid() and status='submitted');
create policy "submissions admin update" on public.task_submissions for update to authenticated using(public.is_admin()) with check(public.is_admin());
create policy "wallet own read" on public.wallets for select to authenticated using(user_id=auth.uid() or public.is_admin());
create policy "transactions own read" on public.transactions for select to authenticated using(user_id=auth.uid() or public.is_admin());
create policy "checkins own read" on public.daily_checkins for select to authenticated using(user_id=auth.uid() or public.is_admin());
create policy "referrals own read" on public.referrals for select to authenticated using(referrer_id=auth.uid() or referred_user_id=auth.uid() or public.is_admin());
create policy "withdrawals own read" on public.withdrawal_requests for select to authenticated using(user_id=auth.uid() or public.is_admin());
create policy "withdrawals own insert" on public.withdrawal_requests for insert to authenticated with check(user_id=auth.uid() and status='pending');
create policy "withdrawals admin update" on public.withdrawal_requests for update to authenticated using(public.is_admin()) with check(public.is_admin());
create policy "settings read" on public.admin_settings for select to authenticated using(true);
create policy "settings admin update" on public.admin_settings for update to authenticated using(public.is_admin()) with check(public.is_admin());
create policy "audit admin read" on public.admin_audit_logs for select to authenticated using(public.is_admin());

-- Storage: create two PRIVATE buckets in Storage UI: payment-proofs and task-proofs.
-- Storage object policies below enforce per-user folders and admin read access.
create policy "own proof upload" on storage.objects for insert to authenticated with check(bucket_id in ('payment-proofs','task-proofs') and (storage.foldername(name))[1]=auth.uid()::text);
create policy "own proof read" on storage.objects for select to authenticated using(bucket_id in ('payment-proofs','task-proofs') and ((storage.foldername(name))[1]=auth.uid()::text or public.is_admin()));
create policy "own proof delete" on storage.objects for delete to authenticated using(bucket_id in ('payment-proofs','task-proofs') and (storage.foldername(name))[1]=auth.uid()::text);

-- SECURITY NOTE: after the first account registers, promote its profile manually in SQL:
-- update public.profiles set role='admin' where email='your-admin@example.com';