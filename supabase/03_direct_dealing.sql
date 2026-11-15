-- =====================================================================
--  DentaCore Shift — التحديث 3: «التعامل المباشر طويل الأمد»
--  عمولة التعريف = الرسوم − كل العمولات اللي العيادة دفعتها على شيفتات نفس الطبيب
--  بحد أدنى (hire_min). شغّله مرة واحدة في SQL Editor.
-- =====================================================================
create or replace function public.hire_quote(p_doctor uuid) returns table (fee int, discount int, amount_due int)
language plpgsql security definer set search_path = public as $$
declare cid uuid := my_clinic_id(); paid int; f int := setting_int('hire_fee');
begin
  if cid is null then raise exception 'للعيادات فقط'; end if;
  select coalesce(sum(b.platform_fee),0) into paid
    from bookings b join shifts s on s.id = b.shift_id
   where b.doctor_id = p_doctor and s.clinic_id = cid and b.status = 'completed';
  return query select f, greatest(0, least(paid, f - setting_int('hire_min'))),
                      f - greatest(0, least(paid, f - setting_int('hire_min')));
end $$;

create or replace function public.request_hire(p_doctor uuid) returns uuid
language plpgsql security definer set search_path = public as $$
declare cid uuid := my_clinic_id(); q record; hid uuid;
begin
  if cid is null then raise exception 'للعيادات فقط'; end if;
  if not exists (select 1 from bookings b join shifts s on s.id=b.shift_id
                  where b.doctor_id = p_doctor and s.clinic_id = cid) then
    raise exception 'التعامل المباشر متاح لطبيب اشتغل عندك على المنصة';
  end if;
  select id into hid from hires where clinic_id = cid and doctor_id = p_doctor
     and status in ('pending_payment','payment_review');
  if hid is not null then return hid; end if;
  select * into q from hire_quote(p_doctor);
  insert into hires (clinic_id, doctor_id, fee, discount, amount_due)
    values (cid, p_doctor, q.fee, q.discount, q.amount_due) returning id into hid;
  return hid;
end $$;

revoke execute on function public.hire_quote(uuid), public.request_hire(uuid) from anon, public;
grant execute on function public.hire_quote(uuid), public.request_hire(uuid) to authenticated;
select 'تم التحديث ✓' as result;
