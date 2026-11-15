-- 0.9.9: a faster relay between the phone and the computer.
--
-- 1. When a packet is stored, the recipient device is pinged on a private Realtime Broadcast channel
--    (topic "opengrok:<device id>"). The ping is an empty JSON object: no packet data, ids or sizes.
--    Apps that see the ping check their mailbox at once instead of waiting for their next timer.
-- 2. Only the signed-in owner of a device can listen on that device's channel.
-- 3. Mailbox checks no longer write: expired packets are skipped here and deleted when packets are sent.
-- 4. The per-account mailbox limit uses an index instead of scanning the table.
--
-- Older apps keep working: they ignore the channel and keep polling.

create index if not exists opengrok_packets_owner on public.opengrok_packets(owner_id);

create or replace function public.opengrok_poll(device_id uuid)
returns table(id uuid,sender uuid,recipient uuid,kind text,ciphertext text,created_at timestamptz)
language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null or not exists(select 1 from public.opengrok_devices d where d.id = device_id and d.owner_id = auth.uid()) then raise exception 'Unknown device'; end if;
  return query select p.id,p.sender,p.recipient,p.kind,p.ciphertext,p.created_at from public.opengrok_packets p
    where p.recipient = device_id and p.owner_id = auth.uid() and p.expires_at >= now() order by p.created_at limit 8;
end $$;

create or replace function public.opengrok_wake()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  begin
    perform realtime.send('{}'::jsonb, 'packet', 'opengrok:' || new.recipient::text, true);
  exception when others then
    -- A failed ping must never stop the packet itself. Apps fall back to polling.
    null;
  end;
  return null;
end $$;
revoke all on function public.opengrok_wake() from public, anon, authenticated;

drop trigger if exists opengrok_packets_wake on public.opengrok_packets;
create trigger opengrok_packets_wake after insert on public.opengrok_packets
  for each row execute function public.opengrok_wake();

drop policy if exists "opengrok devices hear their own wake channel" on realtime.messages;
create policy "opengrok devices hear their own wake channel" on realtime.messages
  for select to authenticated
  using (
    realtime.messages.extension = 'broadcast'
    and exists (
      select 1 from public.opengrok_devices d
      where d.owner_id = (select auth.uid())
        and 'opengrok:' || d.id::text = (select realtime.topic())
    )
  );
