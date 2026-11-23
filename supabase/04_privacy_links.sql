-- =====================================================================
--  DentaCore Shift — التحديث 4
--  1) اسم العيادة مايظهرش للطبيب غير بعد تأكيد التحويل (محمي في قاعدة البيانات)
--  2) اللوكيشن بيبعته فريق المنصة على واتساب (مش بيظهر تلقائي للطبيب)
--  3) لينكات تظهر للناس (إنستاباي، فيسبوك، إنستجرام) وتتغير من الإعدادات
--  شغّله مرة واحدة في SQL Editor. آمن لو اتشغّل أكتر من مرة.
-- =====================================================================

-- ---------- 1) إخفاء اسم العيادة ----------
-- المستخدمين يقدروا يقروا الأعمدة دي بس من جدول العيادات. الاسم والترخيص مش من ضمنها.
revoke select on clinics from authenticated, anon;
grant select (id, owner_id, area, equipment, status, photo_paths, created_at) on clinics to authenticated;

-- بيانات العيادة كاملة: لصاحبها وللأدمن بس
create or replace function public.clinic_full(p_ids uuid[] default null) returns setof clinics
language sql stable security definer set search_path = public as $$
  select c.* from clinics c
   where (p_ids is null or c.id = any(p_ids))
     and (is_admin() or c.owner_id = auth.uid())
   order by c.created_at;
$$;

-- أسماء العيادات: للأدمن، ولصاحب العيادة، وللطبيب اللي عنده حجز اتأكد تحويله فيها
create or replace function public.clinic_names(p_ids uuid[]) returns table (id uuid, name text)
language sql stable security definer set search_path = public as $$
  select c.id, c.name from clinics c
   where c.id = any(p_ids)
     and (is_admin() or c.owner_id = auth.uid() or exists (
          select 1 from bookings b join shifts s on s.id = b.shift_id
           where s.clinic_id = c.id and b.doctor_id = auth.uid()
             and b.status in ('confirmed','settlement_due','settlement_review','completed')));
$$;

-- بيانات التواصل: للعيادة والأدمن بس. الطبيب بيوصله اللوكيشن من فريق المنصة على واتساب
create or replace function public.booking_contact(p_booking uuid)
returns table (doctor_phone text, clinic_phone text, address text, map_link text)
language plpgsql security definer set search_path = public as $$
declare b bookings; s shifts; c clinics;
begin
  select * into b from bookings where id = p_booking;
  select * into s from shifts where id = b.shift_id;
  select * into c from clinics where id = s.clinic_id;
  if b.id is null or not coalesce(c.owner_id = auth.uid() or is_admin(), false) then
    return;
  end if;
  if not is_admin() and (b.status not in ('confirmed','settlement_due','settlement_review')
     or s.shift_date - cairo_today() > 1) then
    return;
  end if;
  return query
    select (select phone from contacts where user_id = b.doctor_id),
           (select phone from contacts where user_id = c.owner_id),
           cp.address, cp.map_link
      from clinics c2 left join clinic_private cp on cp.clinic_id = c2.id
     where c2.id = c.id;
end $$;

-- متابعة إرسال اللوكيشن
alter table bookings add column if not exists location_sent boolean not null default false;

create or replace function public.admin_location_sent(p_booking uuid, p_sent boolean default true) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'للأدمن فقط'; end if;
  update bookings set location_sent = p_sent where id = p_booking;
end $$;

-- ---------- 3) اللينكات ----------
insert into settings (key, value) values
  ('instapay_link', '""'),
  ('facebook_url',  '""'),
  ('instagram_url', '""')
on conflict (key) do nothing;

-- لينكات عامة تظهر حتى قبل تسجيل الدخول
create or replace function public.public_links() returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_object_agg(key, value), '{}'::jsonb) from settings
   where key in ('support_whatsapp','facebook_url','instagram_url');
$$;

revoke execute on function public.clinic_full(uuid[]), public.clinic_names(uuid[]), public.booking_contact(uuid),
  public.admin_location_sent(uuid, boolean), public.public_links() from public;
grant execute on function public.clinic_full(uuid[]), public.clinic_names(uuid[]), public.booking_contact(uuid),
  public.admin_location_sent(uuid, boolean) to authenticated;
grant execute on function public.public_links() to anon, authenticated;

select 'تم التحديث ✓' as result;
