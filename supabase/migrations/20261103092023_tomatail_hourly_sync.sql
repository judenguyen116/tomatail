create extension if not exists pg_cron;
select cron.schedule('tomatail-sync-all', '17 * * * *', $$select private.sync_all()$$);
