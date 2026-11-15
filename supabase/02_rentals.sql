-- =====================================================================
--  DentaCore Shift — التحديث 2: الإيجار السنوي للعيادات
--  شغّل الملف ده مرة واحدة في: Supabase → SQL Editor → New query → Run
--  آمن لو اتشغّل أكتر من مرة
-- =====================================================================

do $$ begin
  create type rental_status as enum ('pending','active','rented','closed','rejected');
  create type lead_status   as enum ('new','contacted','viewing','negotiating','signed','lost');
exception when duplicate_object then null; end $$;

-- الإعدادات الجديدة
insert into settings (key, value) values
  ('rental_min_months',      '12'),  -- أقل مدة عقد إيجار (شهور)
  ('rental_commission_months','1'),  -- عمولة الإيجار = كام شهر إيجار
  ('rental_tenant_pct',      '50'),  -- نصيب المستأجر من العمولة %
  ('rental_protect_months',  '12')   -- مدة عدم التجاوز بعد التعريف (شهور)
on conflict (key) do nothing;

-- عيادات للإيجار السنوي (اللي بيعرضها صاحب عيادة)
create table if not exists rentals (
  id            uuid primary key default gen_random_uuid(),
  owner_id      uuid not null references profiles(id) on delete cascade,
  title         text not null check (char_length(title) between 3 and 100),
  area          text not null check (char_length(area) between 2 and 80),
  monthly_rent  int  not null check (monthly_rent between 500 and 10000000),
  min_months    int  not null default 12 check (min_months between 12 and 120),
  size_m2       int  check (size_m2 between 5 and 10000),
  rooms         int  check (rooms between 1 and 50),
  chairs        int  check (chairs between 0 and 50),
  furnished     text check (char_length(furnished) <= 40),
  features      text[] not null default '{}',
  description   text check (char_length(description) <= 1500),
  photo_paths   text[] not null default '{}',
  status        rental_status not null default 'pending',
  reject_reason text,
  created_at    timestamptz not null default now()
);

-- العنوان بالتفصيل: يشوفه صاحب العيادة والأدمن بس
create table if not exists rental_private (
  rental_id uuid primary key references rentals(id) on delete cascade,
  address   text check (char_length(address) <= 300),
  map_link  text check (char_length(map_link) <= 300)
);

-- طلبات المهتمين: يشوفها صاحب الطلب (حالتها بس) والأدمن
create table if not exists rental_leads (
  id            uuid primary key default gen_random_uuid(),
  rental_id     uuid not null references rentals(id) on delete cascade,
  seeker_id     uuid not null references profiles(id) on delete cascade,
  message       text check (char_length(message) <= 600),
  status        lead_status not null default 'new',
  admin_note    text check (char_length(admin_note) <= 1000),
  final_rent    int check (final_rent > 0),
  commission    int,
  tenant_fee    int,
  owner_fee     int,
  tenant_paid   boolean not null default false,
  owner_paid    boolean not null default false,
  terms_version text,
  signed_at     timestamptz,
  created_at    timestamptz not null default now(),
  unique (rental_id, seeker_id)
);

-- حماية: صاحب العيادة ما يغيّرش حالة الإعلان غير لـ "مقفول"
create or replace function public.guard_rental() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or is_admin() then return new; end if;
  if tg_op = 'INSERT' then
    new.status := 'pending'; new.reject_reason := null; new.owner_id := auth.uid();
    if new.min_months < setting_int('rental_min_months') then new.min_months := setting_int('rental_min_months'); end if;
    return new;
  end if;
  if new.owner_id <> old.owner_id then raise exception 'غير مسموح'; end if;
  if new.status is distinct from old.status and new.status <> 'closed' then
    raise exception 'حالة الإعلان يغيرها فريق المنصة';
  end if;
  if new.reject_reason is distinct from old.reject_reason then raise exception 'غير مسموح'; end if;
  if new.min_months < setting_int('rental_min_months') then raise exception 'أقل مدة للعقد % شهر', setting_int('rental_min_months'); end if;
  -- تغيير السعر أو العنوان أو الصور بيرجّع الإعلان للمراجعة
  if old.status in ('active','rejected') and
     (new.title, new.area, new.monthly_rent, new.photo_paths, new.description) is distinct from
     (old.title, old.area, old.monthly_rent, old.photo_paths, old.description) then
    new.status := 'pending';
  end if;
  return new;
end $$;
drop trigger if exists guard_rental on rentals;
create trigger guard_rental before insert or update on rentals for each row execute function public.guard_rental();

-- طلب معاينة/تواصل من طبيب
create or replace function public.request_rental(p_rental uuid, p_message text) returns uuid
language plpgsql security definer set search_path = public as $$
declare r rentals; lid uuid;
begin
  if not exists (select 1 from doctors where id = auth.uid() and status = 'verified') then
    raise exception 'الطلب متاح للأطباء الموثّقين';
  end if;
  select * into r from rentals where id = p_rental;
  if r.id is null or r.status <> 'active' then raise exception 'الإعلان مش متاح'; end if;
  if r.owner_id = auth.uid() then raise exception 'ده إعلانك'; end if;
  insert into rental_leads (rental_id, seeker_id, message, terms_version)
    values (p_rental, auth.uid(), left(coalesce(p_message,''), 600),
            (select terms_version from profiles where id = auth.uid()))
  on conflict (rental_id, seeker_id) do update set message = excluded.message
  returning id into lid;
  return lid;
end $$;

-- عدد المهتمين بإعلان (لصاحبه) من غير ما يعرف هما مين
create or replace function public.rental_interest(p_rental uuid) returns int
language sql stable security definer set search_path = public as $$
  select count(*)::int from rental_leads l join rentals r on r.id = l.rental_id
   where l.rental_id = p_rental and (r.owner_id = auth.uid() or is_admin());
$$;

-- الأدمن: مراجعة الإعلان
create or replace function public.admin_review_rental(p_rental uuid, p_ok boolean, p_reason text default null) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'للأدمن فقط'; end if;
  update rentals set status = case when p_ok then 'active'::rental_status else 'rejected'::rental_status end,
                     reject_reason = case when p_ok then null else p_reason end
   where id = p_rental;
end $$;

-- الأدمن: تسجيل الإمضاء وحساب العمولة (شهر إيجار متقسم على الطرفين)
create or replace function public.admin_sign_rental(p_lead uuid, p_final_rent int) returns void
language plpgsql security definer set search_path = public as $$
declare com int; t int;
begin
  if not is_admin() then raise exception 'للأدمن فقط'; end if;
  if coalesce(p_final_rent,0) <= 0 then raise exception 'اكتب الإيجار الشهري في العقد'; end if;
  com := p_final_rent * setting_int('rental_commission_months');
  t   := round(com * setting_int('rental_tenant_pct') / 100.0);
  update rental_leads set status = 'signed', final_rent = p_final_rent, commission = com,
         tenant_fee = t, owner_fee = com - t, signed_at = now()
   where id = p_lead;
  update rentals set status = 'rented' where id = (select rental_id from rental_leads where id = p_lead);
  update rental_leads set status = 'lost'
   where rental_id = (select rental_id from rental_leads where id = p_lead) and id <> p_lead and status <> 'signed';
end $$;

-- ---------- الصلاحيات ----------
alter table rentals        enable row level security;
alter table rental_private enable row level security;
alter table rental_leads   enable row level security;

drop policy if exists p_rentals_read on rentals;
create policy p_rentals_read on rentals for select to authenticated
  using (status = 'active' or owner_id = auth.uid() or is_admin()
         or exists (select 1 from rental_leads l where l.rental_id = rentals.id and l.seeker_id = auth.uid()));
drop policy if exists p_rentals_ins on rentals;
create policy p_rentals_ins on rentals for insert to authenticated
  with check (owner_id = auth.uid() and exists (select 1 from profiles where id = auth.uid() and role = 'clinic'));
drop policy if exists p_rentals_upd on rentals;
create policy p_rentals_upd on rentals for update to authenticated
  using (owner_id = auth.uid() or is_admin()) with check (owner_id = auth.uid() or is_admin());

drop policy if exists p_rpriv_all on rental_private;
create policy p_rpriv_all on rental_private for all to authenticated
  using (is_admin() or exists (select 1 from rentals r where r.id = rental_id and r.owner_id = auth.uid()))
  with check (is_admin() or exists (select 1 from rentals r where r.id = rental_id and r.owner_id = auth.uid()));

drop policy if exists p_leads_read on rental_leads;
create policy p_leads_read on rental_leads for select to authenticated
  using (seeker_id = auth.uid() or is_admin());
drop policy if exists p_leads_admin on rental_leads;
create policy p_leads_admin on rental_leads for update to authenticated
  using (is_admin()) with check (is_admin());

grant select, insert, update on rentals to authenticated;
grant select, insert, update on rental_private to authenticated;
grant select, update on rental_leads to authenticated;
revoke all on rentals, rental_private, rental_leads from anon;

grant execute on function public.request_rental(uuid,text), public.rental_interest(uuid),
  public.admin_review_rental(uuid,boolean,text), public.admin_sign_rental(uuid,int) to authenticated;
revoke execute on function public.guard_rental() from anon, public;
revoke execute on function public.request_rental(uuid,text), public.rental_interest(uuid),
  public.admin_review_rental(uuid,boolean,text), public.admin_sign_rental(uuid,int) from anon, public;

select 'تم التحديث ✓' as result;
