-- Prices raised because PayPal's fixed fee ($0.30) leaves too little of a $0.50 sale (micropayment rate not yet approved).
update public.catalog set price_cents = 100 where sku in ('item_hat_party','item_hat_wizard','item_hat_crown','item_fit_hoodie','item_fit_cape','item_fit_kimono','xmas_hat_santa','xmas_hat_elf','xmas_hat_holly','xmas_fit_candy','xmas_fit_xmas','xmas_fit_bell');
update public.catalog set price_cents = 150 where sku = 'xmas_pair';
