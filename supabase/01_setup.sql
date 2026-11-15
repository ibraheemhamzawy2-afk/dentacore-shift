-- =====================================================================
--  منصة الشيفتات — إعداد قاعدة البيانات (الإصدار 1)
--  شغّل الملف ده مرة واحدة في: Supabase → SQL Editor → New query → Run
--  مشروع منفصل عن Smile Up
-- =====================================================================

-- ---------- الأنواع ----------
do $$ begin
  create type user_role      as enum ('doctor','clinic','admin');
  create type verify_status  as enum ('pending','verified','rejected');
  create type pricing_mode   as enum ('fixed','percent');
  create type shift_status   as enum ('open','held','booked','completed','cancelled');
  create type booking_status as enum ('pending_payment','payment_review','confirmed',
                                      'settlement_due','settlement_review','completed',
                                      'cancelled','expired');
  create type hire_status    as enum ('pending_payment','payment_review','approved','rejected');
exception when duplicate_object then null; end $$;

-- ---------- الجداول ----------
create table if not exists profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  role        user_role not null default 'doctor',
  full_name   text not null check (char_length(full_name) between 2 and 80),
  area        text check (char_length(area) <= 80),
  created_at  timestamptz not null default now()
);
alter table profiles add column if not exists terms_version text;
alter table profiles add column if not exists terms_accepted_at timestamptz;

-- بيانات التواصل منفصلة ومحمية: لا تظهر لأحد إلا لصاحبها أو للأدمن أو عبر دالة booking_contact
create table if not exists contacts (
  user_id   uuid primary key references profiles(id) on delete cascade,
  phone     text check (phone ~ '^\+?[0-9]{8,15}$'),
  instapay  text check (char_length(instapay) <= 80)
);

create table if not exists doctors (
  id            uuid primary key references profiles(id) on delete cascade,
  syndicate_no  text check (char_length(syndicate_no) <= 30),
  grad_year     int  check (grad_year between 1960 and 2100),
  specialties   text[] not null default '{}',
  bio           text check (char_length(bio) <= 600),
  status        verify_status not null default 'pending',
  card_path     text,
  cert_path     text,
  case_paths    text[] not null default '{}',
  reject_reason text,
  verified_at   timestamptz
);

create table if not exists clinics (
  id            uuid primary key default gen_random_uuid(),
  owner_id      uuid not null unique references profiles(id) on delete cascade,
  name          text not null check (char_length(name) between 2 and 80),
  area          text not null check (char_length(area) between 2 and 80),
  equipment     text[] not null default '{}',
  status        verify_status not null default 'pending',
  license_path  text,
  photo_paths   text[] not null default '{}',
  reject_reason text,
  created_at    timestamptz not null default now()
);

-- العنوان بالتفصيل يظهر فقط للطبيب بعد تأكيد الحجز
create table if not exists clinic_private (
  clinic_id uuid primary key references clinics(id) on delete cascade,
  address   text check (char_length(address) <= 300),
  map_link  text check (char_length(map_link) <= 300)
);

create table if not exists shifts (
  id            uuid primary key default gen_random_uuid(),
  clinic_id     uuid not null references clinics(id) on delete cascade,
  shift_date    date not null,
  start_time    time not null,
  end_time      time not null,
  mode          pricing_mode not null,
  price         int  check (price between 50 and 20000),          -- السعر الثابت
  percent       int  check (percent between 5 and 80),            -- نسبة العيادة من الدخل
  min_guarantee int  check (min_guarantee between 0 and 20000),   -- الحد الأدنى المضمون للعيادة
  includes      text[] not null default '{}',
  notes         text check (char_length(notes) <= 400),
  status        shift_status not null default 'open',
  created_at    timestamptz not null default now(),
  check (end_time > start_time),
  check ((mode = 'fixed' and price is not null) or
         (mode = 'percent' and percent is not null and min_guarantee is not null))
);
create index if not exists shifts_open_idx on shifts (status, shift_date);

create table if not exists bookings (
  id                uuid primary key default gen_random_uuid(),
  shift_id          uuid not null references shifts(id) on delete cascade,
  doctor_id         uuid not null references doctors(id) on delete cascade,
  status            booking_status not null default 'pending_payment',
  amount_due        int  not null,               -- المبلغ المقدم (السعر الثابت أو الحد الأدنى)
  pay_ref           text check (char_length(pay_ref) <= 60),
  proof_path        text,
  hold_expires_at   timestamptz,
  confirmed_at      timestamptz,
  revenue_total     int,                          -- لنظام النسبة
  clinic_share      int,                          -- نصيب العيادة الإجمالي
  platform_fee      int,                          -- عمولة المنصة (تُخصم من نصيب العيادة)
  settle_due        int,                          -- الفرق اللي على الطبيب بعد الشيفت
  settle_ref        text check (char_length(settle_ref) <= 60),
  settle_proof_path text,
  refund_due        int not null default 0,       -- مبلغ يرجع للطبيب عند الإلغاء
  refund_done       boolean not null default false,
  admin_note        text check (char_length(admin_note) <= 300),
  completed_at      timestamptz,
  created_at        timestamptz not null default now()
);
-- حجز واحد نشط فقط لكل شيفت
create unique index if not exists one_active_booking_per_shift
  on bookings (shift_id) where status not in ('cancelled','expired');
create index if not exists bookings_doctor_idx on bookings (doctor_id);

-- فواتير الشيفت في نظام النسبة (بدون أسماء مرضى — حماية بيانات)
create table if not exists invoices (
  id          uuid primary key default gen_random_uuid(),
  booking_id  uuid not null references bookings(id) on delete cascade,
  procedure   text not null check (char_length(procedure) between 2 and 80),
  amount      int  not null check (amount between 1 and 500000),
  created_at  timestamptz not null default now()
);

create table if not exists reviews (
  id          uuid primary key default gen_random_uuid(),
  booking_id  uuid not null references bookings(id) on delete cascade,
  author_id   uuid not null references profiles(id) on delete cascade,
  target_id   uuid not null references profiles(id) on delete cascade,
  rating      int  not null check (rating between 1 and 5),
  comment     text check (char_length(comment) <= 300),
  created_at  timestamptz not null default now(),
  unique (booking_id, author_id)
);

create table if not exists hires (
  id          uuid primary key default gen_random_uuid(),
  clinic_id   uuid not null references clinics(id) on delete cascade,
  doctor_id   uuid not null references doctors(id) on delete cascade,
  fee         int not null,
  discount    int not null default 0,
  amount_due  int not null,
  status      hire_status not null default 'pending_payment',
  pay_ref     text check (char_length(pay_ref) <= 60),
  proof_path  text,
  created_at  timestamptz not null default now(),
  decided_at  timestamptz
);

create table if not exists payouts (
  id         uuid primary key default gen_random_uuid(),
  clinic_id  uuid not null references clinics(id) on delete cascade,
  amount     int  not null check (amount > 0),
  ref        text check (char_length(ref) <= 60),
  note       text check (char_length(note) <= 200),
  paid_at    timestamptz not null default now()
);

create table if not exists settings (
  key   text primary key,
  value jsonb not null
);
insert into settings (key, value) values
  ('commission_fixed_pct',   '15'),    -- عمولة السعر الثابت %
  ('commission_percent_pct', '5'),     -- عمولة نظام النسبة % من دخل الشيفت
  ('commission_min',         '100'),   -- أقل عمولة لشيفت النسبة
  ('monthly_cap_pair',       '600'),   -- سقف العمولة الشهري لنفس الطبيب ونفس العيادة
  ('hire_fee',               '2000'),  -- رسوم التعيين الدائم
  ('hire_min',               '1000'),  -- أقل رسوم بعد الخصم
  ('hire_protect_months',    '6'),
  ('hold_hours',             '3'),     -- مهلة التحويل بعد الحجز
  ('cancel_free_hours',      '24'),
  ('instapay_address',       '"[name]@instapay"'),
  ('wallet_number',          '"[رقم المحفظة]"'),
  ('support_whatsapp',       '"[رقم واتساب الدعم]"')
on conflict (key) do nothing;

-- ---------- دوال مساعدة ----------
create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from profiles where id = auth.uid() and role = 'admin');
$$;

create or replace function public.setting_int(k text) returns int
language sql stable security definer set search_path = public as $$
  select (value #>> '{}')::int from settings where key = k;
$$;

create or replace function public.cairo_today() returns date
language sql stable as $$ select (now() at time zone 'Africa/Cairo')::date; $$;

create or replace function public.my_clinic_id() returns uuid
language sql stable security definer set search_path = public as $$
  select id from clinics where owner_id = auth.uid();
$$;

-- دوال للسياسات (بتمنع الحلقات بين سياسات الجداول)
create or replace function public.shift_clinic(p uuid) returns uuid
language sql stable security definer set search_path = public as $$
  select clinic_id from shifts where id = p;
$$;
create or replace function public.doctor_has_shift(p uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from bookings where shift_id = p and doctor_id = auth.uid());
$$;
create or replace function public.clinic_knows_doctor(p uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from bookings b join shifts s on s.id = b.shift_id
                  where b.doctor_id = p and s.clinic_id = (select id from clinics where owner_id = auth.uid()));
$$;
create or replace function public.can_see_booking(p uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from bookings b join shifts s on s.id = b.shift_id
                  where b.id = p and (b.doctor_id = auth.uid()
                        or s.clinic_id = (select id from clinics where owner_id = auth.uid())
                        or exists (select 1 from profiles where id = auth.uid() and role = 'admin')));
$$;
create or replace function public.can_edit_invoices(p uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from bookings b join shifts s on s.id = b.shift_id
                  where b.id = p and b.doctor_id = auth.uid()
                    and b.status = 'confirmed' and s.mode = 'percent');
$$;

-- إنشاء الملف تلقائيًا عند التسجيل (الدور: طبيب أو عيادة فقط — الأدمن يُضبط يدويًا)
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  r user_role := case when new.raw_user_meta_data->>'role' = 'clinic' then 'clinic'::user_role
                      else 'doctor'::user_role end;
  nm text := case when char_length(trim(coalesce(new.raw_user_meta_data->>'full_name',''))) >= 2
                  then trim(new.raw_user_meta_data->>'full_name') else 'مستخدم جديد' end;
  ph text := nullif(regexp_replace(coalesce(new.raw_user_meta_data->>'phone',''), '[^0-9+]', '', 'g'), '');
begin
  insert into profiles (id, role, full_name, area, terms_version, terms_accepted_at)
    values (new.id, r, left(nm, 80), left(new.raw_user_meta_data->>'area', 80),
            left(new.raw_user_meta_data->>'terms_version', 20),
            case when new.raw_user_meta_data->>'terms_version' is not null then now() end);
  insert into contacts (user_id, phone)
    values (new.id, case when ph ~ '^\+?[0-9]{8,15}$' then ph end);
  if r = 'doctor' then insert into doctors (id) values (new.id); end if;
  return new;
end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- منع تغيير الدور أو حالة التوثيق إلا من الأدمن
create or replace function public.guard_profile() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then return new; end if;  -- من الـ SQL Editor
  if new.role <> old.role and not is_admin() then
    raise exception 'غير مسموح بتغيير نوع الحساب';
  end if;
  return new;
end $$;
drop trigger if exists guard_profile on profiles;
create trigger guard_profile before update on profiles
  for each row execute function public.guard_profile();

create or replace function public.guard_verify() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then return new; end if;
  if not is_admin() then
    if (new.status, new.reject_reason) is distinct from (old.status, old.reject_reason) then
      raise exception 'حالة التوثيق يغيرها الأدمن فقط';
    end if;
    -- أي تعديل في المستندات يرجّع الحساب للمراجعة
    if tg_table_name = 'doctors' then
      if new.verified_at is distinct from old.verified_at then
        raise exception 'حالة التوثيق يغيرها الأدمن فقط';
      end if;
      if (new.card_path, new.cert_path, new.syndicate_no) is distinct from (old.card_path, old.cert_path, old.syndicate_no) then
        if old.status = 'verified' then new.verified_at := null; end if;
        new.status := 'pending';
      end if;
    else
      if new.owner_id <> old.owner_id then raise exception 'غير مسموح'; end if;
      if (new.license_path, new.name) is distinct from (old.license_path, old.name) then
        new.status := 'pending';
      end if;
    end if;
  end if;
  return new;
end $$;
drop trigger if exists guard_doctor on doctors;
create trigger guard_doctor before update on doctors for each row execute function public.guard_verify();
drop trigger if exists guard_clinic on clinics;
create trigger guard_clinic before update on clinics for each row execute function public.guard_verify();

-- العيادة تعدّل الشيفت أو تلغيه وهو مفتوح فقط
create or replace function public.guard_shift() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or is_admin() or current_setting('app.rpc', true) = 'on' then return new; end if;
  if old.status <> 'open' then raise exception 'الشيفت محجوز ولا يمكن تعديله'; end if;
  if new.status not in ('open','cancelled') then raise exception 'غير مسموح'; end if;
  if new.clinic_id <> old.clinic_id then raise exception 'غير مسموح'; end if;
  return new;
end $$;
drop trigger if exists guard_shift on shifts;
create trigger guard_shift before update on shifts for each row execute function public.guard_shift();

-- حساب العمولة ونصيب العيادة (مع سقف شهري لنفس الطبيب ونفس العيادة)
create or replace function public.calc_fee(p_booking uuid, p_revenue int)
returns table (clinic_share int, platform_fee int)
language plpgsql security definer set search_path = public as $$
declare b bookings; s shifts; gross int; fee int; used int; cap int;
begin
  select * into b from bookings where id = p_booking;
  select * into s from shifts where id = b.shift_id;
  if s.mode = 'fixed' then
    gross := s.price;
    fee := round(s.price * setting_int('commission_fixed_pct') / 100.0);
  else
    gross := greatest(round(coalesce(p_revenue,0) * s.percent / 100.0)::int, s.min_guarantee);
    fee := greatest(round(coalesce(p_revenue,0) * setting_int('commission_percent_pct') / 100.0)::int,
                    setting_int('commission_min'));
  end if;
  cap := setting_int('monthly_cap_pair');
  select coalesce(sum(b2.platform_fee),0) into used
    from bookings b2 join shifts s2 on s2.id = b2.shift_id
   where b2.doctor_id = b.doctor_id and s2.clinic_id = s.clinic_id
     and b2.id <> b.id and b2.platform_fee is not null
     and date_trunc('month', s2.shift_date) = date_trunc('month', s.shift_date);
  fee := least(fee, greatest(cap - used, 0), gross);
  return query select gross, fee;
end $$;

-- ---------- دوال العمليات (كل الحجز والدفع يمر من هنا) ----------
create or replace function public.book_shift(p_shift uuid) returns uuid
language plpgsql security definer set search_path = public as $$
declare s shifts; d doctors; bid uuid; amt int;
begin
  select * into d from doctors where id = auth.uid();
  if d.id is null then raise exception 'الحجز للأطباء فقط'; end if;
  if d.status <> 'verified' then raise exception 'لازم ملفك يتوثّق الأول'; end if;
  select * into s from shifts where id = p_shift for update;
  if s.id is null or s.status <> 'open' then raise exception 'الشيفت مش متاح'; end if;
  if s.shift_date < cairo_today() then raise exception 'الشيفت فات معاده'; end if;
  if exists (select 1 from bookings b join shifts x on x.id = b.shift_id
              where b.doctor_id = d.id and b.status not in ('cancelled','expired','completed')
                and x.shift_date = s.shift_date
                and x.start_time < s.end_time and s.start_time < x.end_time) then
    raise exception 'عندك حجز تاني في نفس الوقت';
  end if;
  amt := case when s.mode = 'fixed' then s.price else s.min_guarantee end;
  insert into bookings (shift_id, doctor_id, amount_due, hold_expires_at, status)
    values (s.id, d.id, amt, now() + make_interval(hours => setting_int('hold_hours')),
            case when amt = 0 then 'confirmed'::booking_status else 'pending_payment'::booking_status end)
    returning id into bid;
  perform set_config('app.rpc','on',true);
  update shifts set status = case when amt = 0 then 'booked'::shift_status else 'held'::shift_status end
   where id = s.id;
  if amt = 0 then update bookings set confirmed_at = now() where id = bid; end if;
  return bid;
end $$;

create or replace function public.submit_payment(p_booking uuid, p_ref text, p_proof text) returns void
language plpgsql security definer set search_path = public as $$
declare b bookings;
begin
  select * into b from bookings where id = p_booking for update;
  if b.doctor_id is distinct from auth.uid() then raise exception 'غير مسموح'; end if;
  if b.status <> 'pending_payment' then raise exception 'الحجز مش في انتظار الدفع'; end if;
  if b.hold_expires_at < now() then raise exception 'مهلة التحويل خلصت، احجز تاني'; end if;
  if coalesce(trim(p_ref),'') = '' then raise exception 'اكتب رقم العملية'; end if;
  if p_proof is not null and split_part(p_proof,'/',1) <> auth.uid()::text then raise exception 'ملف غير صالح'; end if;
  update bookings set status = 'payment_review', pay_ref = left(trim(p_ref),60), proof_path = p_proof
   where id = p_booking;
end $$;

create or replace function public.admin_review_payment(p_booking uuid, p_ok boolean, p_note text default null) returns void
language plpgsql security definer set search_path = public as $$
declare b bookings;
begin
  if not is_admin() then raise exception 'للأدمن فقط'; end if;
  select * into b from bookings where id = p_booking for update;
  if b.status <> 'payment_review' then raise exception 'مش في المراجعة'; end if;
  perform set_config('app.rpc','on',true);
  if p_ok then
    update bookings set status = 'confirmed', confirmed_at = now(), admin_note = p_note where id = p_booking;
    update shifts set status = 'booked' where id = b.shift_id;
  else
    -- رفض: يرجع لانتظار الدفع بمهلة جديدة
    update bookings set status = 'pending_payment', admin_note = coalesce(p_note,'التحويل مش واضح'),
           hold_expires_at = now() + make_interval(hours => setting_int('hold_hours'))
     where id = p_booking;
  end if;
end $$;

create or replace function public.cancel_booking(p_booking uuid) returns void
language plpgsql security definer set search_path = public as $$
declare b bookings; s shifts; starts timestamptz; is_doc boolean; is_cl boolean; late boolean;
begin
  select * into b from bookings where id = p_booking for update;
  if b.id is null then raise exception 'الحجز غير موجود'; end if;
  select * into s from shifts where id = b.shift_id;
  is_doc := coalesce(b.doctor_id = auth.uid(), false);
  is_cl  := coalesce(s.clinic_id = my_clinic_id(), false);
  if not (is_doc or is_cl or is_admin()) then raise exception 'غير مسموح'; end if;
  if b.status not in ('pending_payment','payment_review','confirmed') then raise exception 'لا يمكن الإلغاء الآن'; end if;
  starts := (s.shift_date + s.start_time) at time zone 'Africa/Cairo';
  -- إلغاء متأخر من الطبيب لحجز مدفوع: المبلغ تعويض للعيادة بعد خصم العمولة
  late := is_doc and not is_admin() and b.status in ('payment_review','confirmed')
          and starts - now() < make_interval(hours => setting_int('cancel_free_hours'));
  perform set_config('app.rpc','on',true);
  update bookings set status = 'cancelled',
         clinic_share = case when late then b.amount_due end,
         platform_fee = case when late then round(b.amount_due * setting_int('commission_fixed_pct') / 100.0) end,
         refund_due = case
           when b.status = 'pending_payment' then 0
           when is_cl or is_admin() then b.amount_due                         -- العيادة لغت: الطبيب يسترد كامل
           when starts - now() >= make_interval(hours => setting_int('cancel_free_hours')) then b.amount_due
           else 0 end
   where id = p_booking;
  update shifts set status = case when is_cl then 'cancelled'::shift_status else 'open'::shift_status end
   where id = s.id;
end $$;

-- إنهاء الشيفت: الثابت يكتمل، والنسبة تُحسب من الفواتير
create or replace function public.finish_shift(p_booking uuid) returns void
language plpgsql security definer set search_path = public as $$
declare b bookings; s shifts; rev int; r record;
begin
  select * into b from bookings where id = p_booking for update;
  if b.id is null then raise exception 'الحجز غير موجود'; end if;
  select * into s from shifts where id = b.shift_id;
  if not coalesce(b.doctor_id = auth.uid() or s.clinic_id = my_clinic_id() or is_admin(), false) then raise exception 'غير مسموح'; end if;
  if b.status <> 'confirmed' then raise exception 'الحجز مش مؤكد'; end if;
  if (s.shift_date + s.start_time) at time zone 'Africa/Cairo' > now() then raise exception 'الشيفت لسه ما بدأش'; end if;
  select coalesce(sum(amount),0) into rev from invoices where booking_id = b.id;
  select * into r from calc_fee(b.id, rev);
  perform set_config('app.rpc','on',true);
  update bookings set revenue_total = case when s.mode='percent' then rev end,
         clinic_share = r.clinic_share, platform_fee = r.platform_fee,
         settle_due = greatest(r.clinic_share - b.amount_due, 0),
         status = case when r.clinic_share - b.amount_due > 0 then 'settlement_due'::booking_status
                       else 'completed'::booking_status end,
         completed_at = case when r.clinic_share - b.amount_due > 0 then null else now() end
   where id = b.id;
  update shifts set status = 'completed' where id = s.id;
end $$;

create or replace function public.submit_settlement(p_booking uuid, p_ref text, p_proof text) returns void
language plpgsql security definer set search_path = public as $$
declare b bookings;
begin
  select * into b from bookings where id = p_booking for update;
  if b.doctor_id is distinct from auth.uid() then raise exception 'غير مسموح'; end if;
  if b.status <> 'settlement_due' then raise exception 'مفيش مبلغ مستحق'; end if;
  if coalesce(trim(p_ref),'') = '' then raise exception 'اكتب رقم العملية'; end if;
  if p_proof is not null and split_part(p_proof,'/',1) <> auth.uid()::text then raise exception 'ملف غير صالح'; end if;
  update bookings set status = 'settlement_review', settle_ref = left(trim(p_ref),60), settle_proof_path = p_proof
   where id = p_booking;
end $$;

create or replace function public.admin_review_settlement(p_booking uuid, p_ok boolean, p_note text default null) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'للأدمن فقط'; end if;
  update bookings set status = case when p_ok then 'completed'::booking_status else 'settlement_due'::booking_status end,
         completed_at = case when p_ok then now() end, admin_note = p_note
   where id = p_booking and status = 'settlement_review';
  if not found then raise exception 'مش في المراجعة'; end if;
end $$;

-- رقم التليفون والعنوان يظهروا فقط من يوم قبل الشيفت لحد نهايته
create or replace function public.booking_contact(p_booking uuid)
returns table (doctor_phone text, clinic_phone text, address text, map_link text)
language plpgsql security definer set search_path = public as $$
declare b bookings; s shifts; c clinics;
begin
  select * into b from bookings where id = p_booking;
  select * into s from shifts where id = b.shift_id;
  select * into c from clinics where id = s.clinic_id;
  if b.id is null or not coalesce(b.doctor_id = auth.uid() or c.owner_id = auth.uid() or is_admin(), false) then
    raise exception 'غير مسموح';
  end if;
  if not is_admin() and (b.status not in ('confirmed','settlement_due','settlement_review')
     or s.shift_date - cairo_today() > 1) then
    return;  -- لسه بدري: لا تظهر بيانات التواصل
  end if;
  return query
    select (select phone from contacts where user_id = b.doctor_id),
           (select phone from contacts where user_id = c.owner_id),
           cp.address, cp.map_link
      from clinics c2 left join clinic_private cp on cp.clinic_id = c2.id
     where c2.id = c.id;
end $$;

-- التعيين الدائم: رسوم ثابتة ناقص نص العمولات السابقة بين نفس الطرفين
create or replace function public.hire_quote(p_doctor uuid) returns table (fee int, discount int, amount_due int)
language plpgsql security definer set search_path = public as $$
declare cid uuid := my_clinic_id(); paid int; f int := setting_int('hire_fee');
begin
  if cid is null then raise exception 'للعيادات فقط'; end if;
  select coalesce(sum(b.platform_fee),0) into paid
    from bookings b join shifts s on s.id = b.shift_id
   where b.doctor_id = p_doctor and s.clinic_id = cid and b.status = 'completed';
  return query select f, least(paid / 2, f - setting_int('hire_min')),
                      f - least(paid / 2, f - setting_int('hire_min'));
end $$;

create or replace function public.request_hire(p_doctor uuid) returns uuid
language plpgsql security definer set search_path = public as $$
declare cid uuid := my_clinic_id(); q record; hid uuid;
begin
  if cid is null then raise exception 'للعيادات فقط'; end if;
  if not exists (select 1 from bookings b join shifts s on s.id=b.shift_id
                  where b.doctor_id = p_doctor and s.clinic_id = cid) then
    raise exception 'التعيين متاح لطبيب اشتغل عندك على المنصة';
  end if;
  select id into hid from hires where clinic_id = cid and doctor_id = p_doctor
     and status in ('pending_payment','payment_review');
  if hid is not null then return hid; end if;
  select * into q from hire_quote(p_doctor);
  insert into hires (clinic_id, doctor_id, fee, discount, amount_due)
    values (cid, p_doctor, q.fee, q.discount, q.amount_due) returning id into hid;
  return hid;
end $$;

create or replace function public.submit_hire_payment(p_hire uuid, p_ref text, p_proof text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if coalesce(trim(p_ref),'') = '' then raise exception 'اكتب رقم العملية'; end if;
  if p_proof is not null and split_part(p_proof,'/',1) <> auth.uid()::text then raise exception 'ملف غير صالح'; end if;
  update hires set status = 'payment_review', pay_ref = left(trim(p_ref),60), proof_path = p_proof
   where id = p_hire and clinic_id = my_clinic_id() and status = 'pending_payment';
  if not found then raise exception 'غير مسموح'; end if;
end $$;

create or replace function public.admin_review_hire(p_hire uuid, p_ok boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'للأدمن فقط'; end if;
  update hires set status = case when p_ok then 'approved'::hire_status else 'pending_payment'::hire_status end,
         decided_at = case when p_ok then now() end
   where id = p_hire and status = 'payment_review';
end $$;

create or replace function public.admin_verify(p_kind text, p_id uuid, p_ok boolean, p_reason text default null) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'للأدمن فقط'; end if;
  if p_kind = 'doctor' then
    update doctors set status = case when p_ok then 'verified'::verify_status else 'rejected'::verify_status end,
           verified_at = case when p_ok then now() end, reject_reason = case when p_ok then null else p_reason end
     where id = p_id;
  else
    update clinics set status = case when p_ok then 'verified'::verify_status else 'rejected'::verify_status end,
           reject_reason = case when p_ok then null else p_reason end
     where id = p_id;
  end if;
end $$;

-- رصيد العيادة: نصيبها من الشيفتات المكتملة ناقص اللي اتحوّل لها
create or replace function public.clinic_balance(p_clinic uuid default null)
returns table (earned int, paid int, balance int)
language plpgsql security definer set search_path = public as $$
declare cid uuid := coalesce(p_clinic, my_clinic_id()); e int; p int;
begin
  if not (cid = my_clinic_id() or is_admin()) then raise exception 'غير مسموح'; end if;
  select coalesce(sum(b.clinic_share - b.platform_fee),0) into e
    from bookings b join shifts s on s.id = b.shift_id
   where s.clinic_id = cid
     and (b.status = 'completed' or (b.status = 'cancelled' and b.clinic_share is not null));
  select coalesce(sum(amount),0) into p from payouts where clinic_id = cid;
  return query select e, p, e - p;
end $$;

-- تقييم بعد الشيفت (كل طرف يقيّم التاني مرة واحدة)
create or replace function public.add_review(p_booking uuid, p_rating int, p_comment text) returns void
language plpgsql security definer set search_path = public as $$
declare b bookings; s shifts; c clinics; target uuid;
begin
  select * into b from bookings where id = p_booking;
  select * into s from shifts where id = b.shift_id;
  select * into c from clinics where id = s.clinic_id;
  if b.status not in ('completed','settlement_due','settlement_review') then raise exception 'التقييم بعد الشيفت'; end if;
  if auth.uid() = b.doctor_id then target := c.owner_id;
  elsif auth.uid() = c.owner_id then target := b.doctor_id;
  else raise exception 'غير مسموح'; end if;
  insert into reviews (booking_id, author_id, target_id, rating, comment)
    values (b.id, auth.uid(), target, p_rating, left(p_comment,300));
end $$;

-- الطبيب ما حضرش: الحجز يتلغي والمبلغ تعويض للعيادة
create or replace function public.admin_no_show(p_booking uuid) returns void
language plpgsql security definer set search_path = public as $$
declare b bookings;
begin
  if not is_admin() then raise exception 'للأدمن فقط'; end if;
  select * into b from bookings where id = p_booking for update;
  if b.status <> 'confirmed' then raise exception 'الحجز مش مؤكد'; end if;
  perform set_config('app.rpc','on',true);
  update bookings set status = 'cancelled', refund_due = 0, clinic_share = b.amount_due,
         platform_fee = round(b.amount_due * setting_int('commission_fixed_pct') / 100.0),
         admin_note = 'الطبيب لم يحضر'
   where id = p_booking;
  update shifts set status = 'completed' where id = b.shift_id;
end $$;

create or replace function public.admin_mark_refund(p_booking uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'للأدمن فقط'; end if;
  update bookings set refund_done = true where id = p_booking and refund_due > 0;
end $$;

-- إلغاء الحجوزات اللي ما اتدفعتش في المهلة (بتشتغل كل 10 دقايق)
create or replace function public.expire_holds() returns void
language plpgsql security definer set search_path = public as $$
begin
  perform set_config('app.rpc','on',true);
  with ex as (
    update bookings set status = 'expired'
     where status = 'pending_payment' and hold_expires_at < now()
     returning shift_id)
  update shifts set status = 'open' where id in (select shift_id from ex) and status = 'held';
  -- الشيفتات المفتوحة اللي فات معادها
  update shifts set status = 'cancelled' where status = 'open' and shift_date < cairo_today();
end $$;

-- مراقبة التسرب: طبيب وعيادة اشتغلوا 3 مرات أو أكتر وآخر شيفت من أكتر من 30 يوم
create or replace view public.admin_pairs with (security_invoker = true) as
  select s.clinic_id, b.doctor_id, count(*) as shifts_together, max(s.shift_date) as last_shift
    from bookings b join shifts s on s.id = b.shift_id
   where b.status = 'completed'
   group by s.clinic_id, b.doctor_id
  having count(*) >= 3 and max(s.shift_date) < cairo_today() - 30;

-- ---------- سياسات الأمان (RLS) ----------
alter table profiles       enable row level security;
alter table contacts       enable row level security;
alter table doctors        enable row level security;
alter table clinics        enable row level security;
alter table clinic_private enable row level security;
alter table shifts         enable row level security;
alter table bookings       enable row level security;
alter table invoices       enable row level security;
alter table reviews        enable row level security;
alter table hires          enable row level security;
alter table payouts        enable row level security;
alter table settings       enable row level security;

-- الأسماء والمناطق ظاهرة للمسجلين فقط
drop policy if exists p_profiles_read on profiles;
create policy p_profiles_read on profiles for select to authenticated using (true);
drop policy if exists p_profiles_upd on profiles;
create policy p_profiles_upd on profiles for update to authenticated
  using (id = auth.uid() or is_admin()) with check (id = auth.uid() or is_admin());

drop policy if exists p_contacts_all on contacts;
create policy p_contacts_all on contacts for all to authenticated
  using (user_id = auth.uid() or is_admin()) with check (user_id = auth.uid() or is_admin());

drop policy if exists p_doctors_read on doctors;
create policy p_doctors_read on doctors for select to authenticated
  using (status = 'verified' or id = auth.uid() or is_admin() or clinic_knows_doctor(id));
drop policy if exists p_doctors_upd on doctors;
create policy p_doctors_upd on doctors for update to authenticated
  using (id = auth.uid() or is_admin()) with check (id = auth.uid() or is_admin());

drop policy if exists p_clinics_read on clinics;
create policy p_clinics_read on clinics for select to authenticated
  using (status = 'verified' or owner_id = auth.uid() or is_admin());
drop policy if exists p_clinics_ins on clinics;
create policy p_clinics_ins on clinics for insert to authenticated
  with check (owner_id = auth.uid() and status = 'pending'
              and exists (select 1 from profiles where id = auth.uid() and role = 'clinic'));
drop policy if exists p_clinics_upd on clinics;
create policy p_clinics_upd on clinics for update to authenticated
  using (owner_id = auth.uid() or is_admin()) with check (owner_id = auth.uid() or is_admin());

drop policy if exists p_cpriv_all on clinic_private;
create policy p_cpriv_all on clinic_private for all to authenticated
  using (clinic_id = my_clinic_id() or is_admin()) with check (clinic_id = my_clinic_id() or is_admin());

drop policy if exists p_shifts_read on shifts;
create policy p_shifts_read on shifts for select to authenticated
  using ((status = 'open' and shift_date >= cairo_today()
          and exists (select 1 from clinics c where c.id = shifts.clinic_id and c.status = 'verified'))
         or clinic_id = my_clinic_id() or is_admin() or doctor_has_shift(id));
drop policy if exists p_shifts_ins on shifts;
create policy p_shifts_ins on shifts for insert to authenticated
  with check (clinic_id = my_clinic_id() and status = 'open' and shift_date >= cairo_today()
              and exists (select 1 from clinics c where c.id = clinic_id and c.status = 'verified'));
drop policy if exists p_shifts_upd on shifts;
create policy p_shifts_upd on shifts for update to authenticated
  using (clinic_id = my_clinic_id() or is_admin()) with check (clinic_id = my_clinic_id() or is_admin());

-- الحجوزات: قراءة فقط، والكتابة كلها عبر الدوال
drop policy if exists p_bookings_read on bookings;
create policy p_bookings_read on bookings for select to authenticated
  using (doctor_id = auth.uid() or is_admin() or shift_clinic(shift_id) = my_clinic_id());

drop policy if exists p_invoices_read on invoices;
create policy p_invoices_read on invoices for select to authenticated
  using (can_see_booking(booking_id));
drop policy if exists p_invoices_ins on invoices;
create policy p_invoices_ins on invoices for insert to authenticated
  with check (can_edit_invoices(booking_id));
drop policy if exists p_invoices_del on invoices;
create policy p_invoices_del on invoices for delete to authenticated
  using (can_edit_invoices(booking_id));

drop policy if exists p_reviews_read on reviews;
create policy p_reviews_read on reviews for select to authenticated using (true);

drop policy if exists p_hires_read on hires;
create policy p_hires_read on hires for select to authenticated
  using (clinic_id = my_clinic_id() or doctor_id = auth.uid() or is_admin());

drop policy if exists p_payouts_read on payouts;
create policy p_payouts_read on payouts for select to authenticated
  using (clinic_id = my_clinic_id() or is_admin());
drop policy if exists p_payouts_admin on payouts;
create policy p_payouts_admin on payouts for insert to authenticated with check (is_admin());

drop policy if exists p_settings_read on settings;
create policy p_settings_read on settings for select to authenticated using (true);
drop policy if exists p_settings_admin on settings;
create policy p_settings_admin on settings for update to authenticated using (is_admin()) with check (is_admin());

-- ---------- الصلاحيات: لا شيء للزائر غير المسجل ----------
revoke all on all tables in schema public from anon;
revoke all on all functions in schema public from anon, public;
grant select, insert, update, delete on all tables in schema public to authenticated;
revoke insert, update, delete on bookings, reviews, hires, payouts from authenticated;
grant insert on payouts to authenticated;  -- مقيدة بسياسة الأدمن
grant execute on function
  public.is_admin(), public.setting_int(text), public.cairo_today(), public.my_clinic_id(),
  public.book_shift(uuid), public.submit_payment(uuid,text,text),
  public.admin_review_payment(uuid,boolean,text), public.cancel_booking(uuid),
  public.finish_shift(uuid), public.submit_settlement(uuid,text,text),
  public.admin_review_settlement(uuid,boolean,text), public.booking_contact(uuid),
  public.hire_quote(uuid), public.request_hire(uuid), public.submit_hire_payment(uuid,text,text),
  public.admin_review_hire(uuid,boolean), public.admin_verify(text,uuid,boolean,text),
  public.clinic_balance(uuid), public.add_review(uuid,int,text), public.admin_mark_refund(uuid), public.admin_no_show(uuid),
  public.shift_clinic(uuid), public.doctor_has_shift(uuid), public.clinic_knows_doctor(uuid),
  public.can_see_booking(uuid), public.can_edit_invoices(uuid)
  to authenticated;
-- دوال داخلية لا تُستدعى من الموقع
revoke execute on function public.calc_fee(uuid,int), public.expire_holds(),
  public.handle_new_user(), public.guard_profile(), public.guard_verify(), public.guard_shift()
  from authenticated;

-- ---------- التخزين ----------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types) values
  ('docs',  'docs',  false, 5242880, array['image/jpeg','image/png','image/webp','application/pdf']),
  ('media', 'media', true,  3145728, array['image/jpeg','image/png','image/webp'])
on conflict (id) do update set public = excluded.public, file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

-- كل مستخدم يرفع في فولدر باسمه فقط
drop policy if exists s_docs_ins on storage.objects;
create policy s_docs_ins on storage.objects for insert to authenticated
  with check (bucket_id in ('docs','media') and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists s_docs_read on storage.objects;
create policy s_docs_read on storage.objects for select to authenticated
  using (bucket_id = 'media' or (bucket_id = 'docs'
         and ((storage.foldername(name))[1] = auth.uid()::text or public.is_admin())));
drop policy if exists s_docs_del on storage.objects;
create policy s_docs_del on storage.objects for delete to authenticated
  using (bucket_id in ('docs','media') and (storage.foldername(name))[1] = auth.uid()::text);

-- ---------- المهام الدورية ----------
-- لو ظهر خطأ هنا: فعّل pg_cron من Database → Extensions وشغّل الجزء ده بس تاني
create extension if not exists pg_cron;
select cron.unschedule(jobid) from cron.job where jobname = 'expire-holds';
select cron.schedule('expire-holds', '*/10 * * * *', $$select public.expire_holds()$$);

-- =====================================================================
-- بعد ما تعمل حسابك من الموقع، شغّل السطر ده بإيميلك علشان تبقى أدمن:
-- update profiles set role = 'admin' where id = (select id from auth.users where email = 'YOUR@EMAIL.com');
-- =====================================================================
