-- Live smoke test for 20261115120000_delete_account.sql: no email, credentials or persistent test accounts.
-- Everything is rolled back. Run after verify-rollback.sql.
begin;
insert into auth.users(id) values ('d0b418e3-8581-4f21-b136-cf0039f1a001'), ('d0b418e3-8581-4f21-b136-cf0039f1a002');
-- Two accounts, each with a Mac, a phone, a packet in flight and a pin.
do $$
declare owner uuid; mac uuid; phone uuid; n int;
begin
  for n in 1..2 loop
    owner := ('d0b418e3-8581-4f21-b136-cf0039f1a00' || n)::uuid;
    mac := ('d0b418e3-8581-4f21-b136-cf0039f1b0' || n || '1')::uuid;
    phone := ('d0b418e3-8581-4f21-b136-cf0039f1b0' || n || '2')::uuid;
    perform set_config('request.jwt.claim.sub', owner::text, true);
    perform set_config('role', 'authenticated', true);
    perform public.opengrok_register_device(mac, 'Mac', 'host', repeat('A',43)||'=', true);
    perform public.opengrok_register_device(phone, 'Phone', 'controller', repeat('B',43)||'=', true);
    perform public.opengrok_send(gen_random_uuid(), phone, mac, 'request', repeat('X',100));
    perform public.opengrok_set_bot_pin(mac, gen_random_uuid(), true, false);
    perform set_config('role', 'postgres', true);
  end loop;
end $$;
-- An anonymous caller can't delete anything.
set local role anon;
do $$ begin
  begin perform public.opengrok_delete_account(); raise exception 'anon was allowed to call delete';
  exception when insufficient_privilege then null; end;
end $$;
reset role;
-- Account 1 deletes itself.
select set_config('request.jwt.claim.sub','d0b418e3-8581-4f21-b136-cf0039f1a001',true);
set local role authenticated;
select public.opengrok_delete_account();
reset role;
do $$ declare n int; begin
  select count(*) into n from auth.users where id = 'd0b418e3-8581-4f21-b136-cf0039f1a001'; if n <> 0 then raise exception 'Auth user not deleted'; end if;
  select count(*) into n from public.opengrok_devices where owner_id = 'd0b418e3-8581-4f21-b136-cf0039f1a001'; if n <> 0 then raise exception 'Devices not deleted'; end if;
  select count(*) into n from public.opengrok_packets where owner_id = 'd0b418e3-8581-4f21-b136-cf0039f1a001'; if n <> 0 then raise exception 'Packets not deleted'; end if;
  select count(*) into n from public.opengrok_bot_pins where owner_id = 'd0b418e3-8581-4f21-b136-cf0039f1a001'; if n <> 0 then raise exception 'Pins not deleted'; end if;
  -- Account 2 is untouched.
  select count(*) into n from auth.users where id = 'd0b418e3-8581-4f21-b136-cf0039f1a002'; if n <> 1 then raise exception 'Other account deleted'; end if;
  select count(*) into n from public.opengrok_devices where owner_id = 'd0b418e3-8581-4f21-b136-cf0039f1a002'; if n <> 2 then raise exception 'Other account devices touched'; end if;
  select count(*) into n from public.opengrok_packets where owner_id = 'd0b418e3-8581-4f21-b136-cf0039f1a002'; if n <> 1 then raise exception 'Other account packets touched'; end if;
  select count(*) into n from public.opengrok_bot_pins where owner_id = 'd0b418e3-8581-4f21-b136-cf0039f1a002'; if n <> 1 then raise exception 'Other account pins touched'; end if;
end $$;
-- Signed out: refused.
select set_config('request.jwt.claim.sub','',true);
set local role authenticated;
do $$ begin
  begin perform public.opengrok_delete_account(); raise exception 'signed-out call was allowed';
  exception when raise_exception then if sqlerrm <> 'Sign-in required' then raise; end if; end;
end $$;
reset role;
select 'PASS: deletes only the caller''s account, devices, packets and pins; anon and signed-out calls refused; fixtures rolled back' as result;
rollback;
