-- Munchies: setup database order untuk Supabase.
-- Cara guna: Supabase Dashboard → SQL Editor → New query → paste semua → Run.
-- Selamat untuk run semula (idempotent).

-- 1. Had stok seminggu. Tukar nombor 25 di sini kalau nak ubah.
create or replace function public.weekly_stock()
returns int language sql immutable as $$ select 25 $$;

-- 2. Jadual order
create table if not exists public.orders (
  id uuid primary key,
  created_at timestamptz not null default now(),
  name text not null check (char_length(name) between 2 and 60),
  phone text not null check (phone ~ '^\+?[0-9]{9,13}$'),
  quantity int not null check (quantity between 1 and 5),
  area text not null check (area in ('KKA', 'KKB', 'KKC', 'NR')),
  address text not null check (char_length(address) between 2 and 200),
  payment_method text not null check (payment_method in ('DuitNow QR', 'Transfer')),
  receipt_path text not null check (receipt_path like id::text || '/%'),
  notes text check (char_length(notes) <= 300),
  total_rm int generated always as (quantity * 6 + 1) stored,
  status text not null default 'baru' check (status in ('baru', 'disahkan', 'dihantar', 'batal'))
);

-- Awal minggu ikut waktu Malaysia (Isnin 12:00 pagi).
create or replace function public.week_start()
returns timestamptz language sql stable as $$
  select date_trunc('week', now() at time zone 'Asia/Kuala_Lumpur') at time zone 'Asia/Kuala_Lumpur'
$$;

-- 3. Baki stok minggu ini (boleh dipanggil oleh website)
create or replace function public.stock_left()
returns int language sql stable security definer set search_path = public as $$
  select greatest(
    weekly_stock() - coalesce(sum(quantity), 0)::int, 0)
  from orders
  where created_at >= week_start() and status <> 'batal'
$$;

-- 4. Setiap order baru: kunci masa & status, dan tolak kalau stok tak cukup
create or replace function public.orders_before_insert()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform pg_advisory_xact_lock(hashtext('munchies_orders'));
  new.created_at := now();
  new.status := 'baru';
  if new.quantity > stock_left() then
    raise exception 'STOK_HABIS' using hint = stock_left()::text;
  end if;
  return new;
end $$;

drop trigger if exists orders_before_insert on public.orders;
create trigger orders_before_insert before insert on public.orders
  for each row execute function public.orders_before_insert();

-- 5. Keselamatan: orang awam boleh HANTAR order sahaja, tak boleh baca/ubah/padam.
alter table public.orders enable row level security;
drop policy if exists "awam boleh hantar order" on public.orders;
create policy "awam boleh hantar order" on public.orders
  for insert to anon, authenticated with check (true);

revoke all on public.orders from anon, authenticated;
grant insert on public.orders to anon, authenticated;
revoke all on function public.stock_left() from public;
grant execute on function public.stock_left() to anon, authenticated;

-- 6. Storage untuk resit (private, max 5MB, gambar/PDF sahaja)
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('receipts', 'receipts', false, 5242880,
        array['image/jpeg', 'image/png', 'image/webp', 'image/heic', 'image/heif', 'application/pdf'])
on conflict (id) do update set
  public = excluded.public,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "awam boleh upload resit" on storage.objects;
create policy "awam boleh upload resit" on storage.objects
  for insert to anon, authenticated with check (bucket_id = 'receipts');

-- 7. Minta API Supabase muat semula senarai fungsi/jadual
notify pgrst, 'reload schema';

-- 8. Semakan: patut keluar satu baris "SETUP OK" dengan baki 25
select 'SETUP OK' as status, public.stock_left() as baki_stok;
