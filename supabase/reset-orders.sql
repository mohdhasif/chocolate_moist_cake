-- Munchies: padam SEMUA order untuk mula semula (start fresh).
-- ⚠️ TAK BOLEH UNDO. Eksport laporan (Excel/PDF) dari page admin dulu kalau nak simpan rekod lama.
-- Rekod stok "jualan online" yang automatik turut dipadam (ikut order). Kuota minggu ni kembali penuh.
-- Rekod stok manual (bakar, rosak...) dan transaksi kewangan TIDAK disentuh.

delete from public.orders;

select 'ORDER DIPADAM' as status,
       (select count(*) from public.orders) as baki_order,
       public.stock_left() as kuota_minggu_ni;

-- PILIHAN: nak kosongkan stok & kewangan juga? Buang tanda "--" pada dua baris bawah, kemudian Run semula.
-- delete from public.stock_movements;
-- delete from public.transactions;

-- Fail resit lama: padam melalui Storage → receipts → pilih semua folder → Delete
-- (Supabase tak benarkan padam fail storage terus melalui SQL).
