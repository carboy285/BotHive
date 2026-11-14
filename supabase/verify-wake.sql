-- Live smoke test for 20261114200000_relay_wake.sql: no email, credentials or persistent test accounts.
-- Everything is rolled back. Run after verify-rollback.sql.
begin;
insert into auth.users(id) values ('b0b418e3-8581-4f21-b136-cf0039f1a001'), ('b0b418e3-8581-4f21-b136-cf0039f1a002');
select set_config('request.jwt.claim.sub','b0b418e3-8581-4f21-b136-cf0039f1a001',true);
set local role authenticated;
do $$
declare n integer; t text; body jsonb; mac constant uuid := 'b0b418e3-8581-4f21-b136-cf0039f1b001'; phone constant uuid := 'b0b418e3-8581-4f21-b136-cf0039f1b002';
begin
  perform public.opengrok_register_device(mac,'Wake Mac','host',repeat('A',43)||'=',true);
  perform public.opengrok_register_device(phone,'Wake phone','controller',repeat('B',43)||'=',true);
  -- A stored packet pings the recipient's channel, with an empty payload. Read as the owner of the
  -- database: the listening policy is checked separately below.
  perform public.opengrok_send('b0b418e3-8581-4f21-b136-cf0039f1c001',phone,mac,'request',repeat('X',100));
  reset role;
  select m.topic, m.payload into t, body from realtime.messages m where m.topic = 'opengrok:' || mac::text order by m.inserted_at desc limit 1;
  if t is null then raise exception 'No wake ping for the recipient'; end if;
  if body <> '{}'::jsonb then raise exception 'Wake ping must carry no data, got %', body; end if;
  -- The sender is not pinged.
  select count(*) into n from realtime.messages m where m.topic = 'opengrok:' || phone::text;
  if n <> 0 then raise exception 'Sender was pinged'; end if;
  -- Expired packets are not delivered, and polling does not delete anything.
  update public.opengrok_packets set expires_at = now() - interval '1 second' where id = 'b0b418e3-8581-4f21-b136-cf0039f1c001';
  set local role authenticated;
  select count(*) into n from public.opengrok_poll(mac);
  if n <> 0 then raise exception 'Expired packet was delivered'; end if;
  reset role;
  select count(*) into n from public.opengrok_packets where id = 'b0b418e3-8581-4f21-b136-cf0039f1c001';
  if n <> 1 then raise exception 'Polling deleted a packet'; end if;
  set local role authenticated;
end $$;
-- The owner can read its device's channel; another account cannot.
select set_config('realtime.topic','opengrok:b0b418e3-8581-4f21-b136-cf0039f1b001',true);
do $$ declare n integer; begin
  select count(*) into n from realtime.messages;
  if n = 0 then raise exception 'Owner cannot read its own wake channel'; end if;
end $$;
select set_config('request.jwt.claim.sub','b0b418e3-8581-4f21-b136-cf0039f1a002',true);
do $$ declare n integer; begin
  select count(*) into n from realtime.messages;
  if n <> 0 then raise exception 'Another account can read this wake channel'; end if;
end $$;
select 'PASS: wake ping on store, empty payload, recipient only, expired packets skipped, read-only poll, channel isolation; fixtures rolled back' as result;
rollback;
