-- Munchies: page admin (stok kek, order, kewangan).
-- Cara guna: run SELEPAS setup.sql. Supabase Dashboard → SQL Editor → New query → paste semua → Run.
-- Selamat untuk run semula (idempotent).

-- 1. Senarai admin (ikut email akaun Supabase Auth)
create table if not exists public.admins (
  email text primary key check (email = lower(email))
);

create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from admins where email = lower(coalesce(auth.jwt() ->> 'email', '')))
$$;

-- 2. Tetapan kedai (satu baris sahaja)
create table if not exists public.settings (
  id int primary key default 1 check (id = 1),
  weekly_limit int not null default 25 check (weekly_limit between 0 and 1000),
  orders_open boolean not null default true,
  updated_at timestamptz not null default now()
);
insert into public.settings (id) values (1) on conflict (id) do nothing;

-- Had stok kini dibaca dari tetapan
create or replace function public.weekly_stock()
returns int language sql stable security definer set search_path = public as $$
  select coalesce((select weekly_limit from settings where id = 1), 25)
$$;

-- Status kedai untuk website pembeli
create or replace function public.shop_status()
returns json language sql stable security definer set search_path = public as $$
  select json_build_object(
    'open', coalesce((select orders_open from settings where id = 1), true),
    'limit', weekly_stock(),
    'left', stock_left())
$$;
grant execute on function public.shop_status() to anon, authenticated;

-- Order baru: tolak kalau kedai tutup atau stok tak cukup
create or replace function public.orders_before_insert()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform pg_advisory_xact_lock(hashtext('munchies_orders'));
  new.created_at := now();
  new.status := 'baru';
  if not coalesce((select orders_open from settings where id = 1), true) then
    raise exception 'KEDAI_TUTUP';
  end if;
  if new.quantity > stock_left() then
    raise exception 'STOK_HABIS' using hint = stock_left()::text;
  end if;
  return new;
end $$;

-- 3. Order: admin boleh baca & tukar status
alter table public.orders add column if not exists updated_at timestamptz;

-- 4. Stok kek: masuk (bakar) / keluar (jualan, rosak, percuma...)
create table if not exists public.stock_movements (
  id bigint generated always as identity primary key,
  created_at timestamptz not null default now(),
  kind text not null check (kind in ('masuk', 'keluar')),
  qty int not null check (qty between 1 and 1000),
  reason text not null check (reason in ('bakar', 'jualan online', 'jualan luar', 'rosak', 'percuma', 'pelarasan', 'lain-lain')),
  note text check (char_length(note) <= 300),
  order_id uuid unique references public.orders (id) on delete cascade,
  created_by text default lower(auth.jwt() ->> 'email')
);

-- Bila order ditanda "dihantar", kek keluar direkod automatik (dan dibatalkan kalau status diundur)
create or replace function public.orders_after_status()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'dihantar' and old.status is distinct from 'dihantar' then
    insert into stock_movements (kind, qty, reason, order_id, note, created_by)
    values ('keluar', new.quantity, 'jualan online', new.id, 'Order #' || upper(left(new.id::text, 8)), lower(auth.jwt() ->> 'email'))
    on conflict (order_id) do nothing;
  elsif old.status = 'dihantar' and new.status <> 'dihantar' then
    delete from stock_movements where order_id = new.id;
  end if;
  return new;
end $$;

create or replace function public.orders_before_update()
returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end $$;

drop trigger if exists orders_before_update on public.orders;
create trigger orders_before_update before update on public.orders
  for each row execute function public.orders_before_update();
drop trigger if exists orders_after_status on public.orders;
create trigger orders_after_status after update of status on public.orders
  for each row execute function public.orders_after_status();

-- 5. Kewangan: modal, belanja, jualan luar, lain-lain
create table if not exists public.transactions (
  id bigint generated always as identity primary key,
  created_at timestamptz not null default now(),
  tx_date date not null default (now() at time zone 'Asia/Kuala_Lumpur')::date,
  kind text not null check (kind in ('modal', 'belanja', 'jualan luar', 'lain-lain masuk')),
  amount numeric(10, 2) not null check (amount > 0 and amount < 100000),
  note text check (char_length(note) <= 300),
  created_by text default lower(auth.jwt() ->> 'email')
);

-- 6. Keselamatan: hanya admin
alter table public.admins enable row level security;
alter table public.settings enable row level security;
alter table public.stock_movements enable row level security;
alter table public.transactions enable row level security;

revoke all on public.admins, public.settings, public.stock_movements, public.transactions from anon, authenticated;
grant select on public.admins to authenticated;
grant select, update (weekly_limit, orders_open, updated_at) on public.settings to authenticated;
grant select, insert, delete on public.stock_movements to authenticated;
grant select, insert, delete on public.transactions to authenticated;
grant select, update (status) on public.orders to authenticated;

drop policy if exists "admin baca admin" on public.admins;
create policy "admin baca admin" on public.admins for select to authenticated using (is_admin());

drop policy if exists "admin baca tetapan" on public.settings;
create policy "admin baca tetapan" on public.settings for select to authenticated using (is_admin());
drop policy if exists "admin ubah tetapan" on public.settings;
create policy "admin ubah tetapan" on public.settings for update to authenticated using (is_admin()) with check (is_admin());

drop policy if exists "admin baca order" on public.orders;
create policy "admin baca order" on public.orders for select to authenticated using (is_admin());
drop policy if exists "admin ubah order" on public.orders;
create policy "admin ubah order" on public.orders for update to authenticated using (is_admin()) with check (is_admin());

drop policy if exists "admin urus stok" on public.stock_movements;
drop policy if exists "admin baca stok" on public.stock_movements;
create policy "admin baca stok" on public.stock_movements for select to authenticated using (is_admin());
drop policy if exists "admin tambah stok" on public.stock_movements;
create policy "admin tambah stok" on public.stock_movements for insert to authenticated
  with check (is_admin() and order_id is null);
drop policy if exists "admin padam stok" on public.stock_movements;
create policy "admin padam stok" on public.stock_movements for delete to authenticated
  using (is_admin() and order_id is null);

drop policy if exists "admin urus kewangan" on public.transactions;
create policy "admin urus kewangan" on public.transactions for all to authenticated
  using (is_admin()) with check (is_admin());

drop policy if exists "admin baca resit" on storage.objects;
create policy "admin baca resit" on storage.objects for select to authenticated
  using (bucket_id = 'receipts' and public.is_admin());

-- 7. Muat semula API & semakan
notify pgrst, 'reload schema';
select 'ADMIN SETUP OK' as status, (select count(*) from public.admins) as bilangan_admin;

-- 8. LANGKAH TERAKHIR (run berasingan, tukar kepada email admin sebenar):
-- insert into public.admins (email) values ('admin1@email.com'), ('admin2@email.com') on conflict do nothing;
