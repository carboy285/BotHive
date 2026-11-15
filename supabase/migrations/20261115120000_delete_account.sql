-- 10.0: delete your own account from the app (Settings → Account → Delete account).
-- Removes the signed-in user's Auth record and everything the relay holds for them: devices, encrypted packets
-- in flight and Bot pins. Chats and Bots live on the user's own computers and are not touched.
-- Only the caller's own account can be deleted; there is no argument to point at someone else.

create or replace function public.opengrok_delete_account()
returns void language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid();
begin
  if uid is null then raise exception 'Sign-in required'; end if;
  -- The tables below also cascade from auth.users; deleting them explicitly keeps this correct if a later
  -- table forgets its cascade.
  delete from public.opengrok_packets where owner_id = uid;
  delete from public.opengrok_bot_pins where owner_id = uid;
  delete from public.opengrok_devices where owner_id = uid;
  delete from auth.users where id = uid;
end $$;

revoke all on function public.opengrok_delete_account() from public, anon;
grant execute on function public.opengrok_delete_account() to authenticated;
