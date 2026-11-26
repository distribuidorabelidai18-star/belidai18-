-- ============================================================
--  Belidai 18 · Pedidos que llegan por la página de pedidos (vendedores y clientes)
--  • Cada pedido que se envía por WhatsApp queda guardado aquí como "pendiente".
--  • Mientras está pendiente, esas piezas quedan APARTADAS: la página de pedidos
--    ya no las ofrece a otro cliente.
--  • Cuando lo pasas a pedido o a nota de entrega en el programa queda "procesado";
--    si lo cancelas, las piezas vuelven a estar disponibles.
--
--  Supabase → SQL Editor → New query → pegar TODO → Run.
-- ============================================================

create table if not exists public.pedidos_web (
  id           uuid primary key default gen_random_uuid(),
  creado       timestamptz not null default now(),
  estado       text not null default 'pendiente' check (estado in ('pendiente','procesado','cancelado')),
  origen       text,          -- 'vendedor' o 'cliente'
  vendedor     text,
  cliente      text,
  nota         text,
  items        jsonb not null, -- [{c: código, r: referencia, d: descripción, u: unidad, n: cantidad, p: precio}]
  total        numeric,
  revisado     timestamptz,
  revisado_por text,
  destino      text           -- N° de pedido o de nota donde se pasó
);
alter table public.pedidos_web enable row level security;

-- La página pública solo puede MANDAR pedidos nuevos (no puede ver los de otros)
drop policy if exists "web_enviar" on public.pedidos_web;
create policy "web_enviar" on public.pedidos_web for insert to anon, authenticated
  with check (
    estado = 'pendiente' and revisado is null and destino is null
    and jsonb_typeof(items) = 'array' and jsonb_array_length(items) between 1 and 300
    and length(coalesce(cliente,'')) between 1 and 200
    and length(coalesce(vendedor,'')) <= 200 and length(coalesce(nota,'')) <= 1000
  );

-- El dueño y sus ayudantes (Carmen, Skarlet) los ven y los marcan como procesados o cancelados
drop policy if exists "web_ver" on public.pedidos_web;
create policy "web_ver" on public.pedidos_web for select to authenticated
  using (public.mi_rol() is distinct from 'vendedor');
drop policy if exists "web_revisar" on public.pedidos_web;
create policy "web_revisar" on public.pedidos_web for update to authenticated
  using (public.mi_rol() is distinct from 'vendedor') with check (public.mi_rol() is distinct from 'vendedor');

grant insert on public.pedidos_web to anon;
grant select, insert, update on public.pedidos_web to authenticated;

-- Piezas apartadas por pedidos pendientes, por código (solo números: no muestra clientes)
create or replace function public.apartado_web() returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_object_agg(c, n), '{}'::jsonb) from (
    select it->>'c' as c, sum(greatest(0, coalesce((it->>'n')::numeric, 0))) as n
    from public.pedidos_web, jsonb_array_elements(items) it
    where estado = 'pendiente' and coalesce(it->>'c','') <> ''
    group by 1) x;
$$;
grant execute on function public.apartado_web() to anon, authenticated;

-- Aviso al teléfono del dueño (si activó los avisos) cuando entra un pedido
create or replace function public.aviso_pedido_web() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if to_regprocedure('public.push_enviar(text,text,text)') is not null then
    perform public.push_enviar(
      '🛒 Pedido nuevo · $' || to_char(coalesce(new.total,0), 'FM999G999G990D00'),
      coalesce(new.cliente,'') || case when coalesce(new.vendedor,'') <> '' then ' · vendedor ' || new.vendedor else ' (cliente)' end
        || ' · ' || jsonb_array_length(new.items) || ' productos',
      'pw-' || new.id);
  end if;
  return new;
exception when others then return new;
end $$;
drop trigger if exists aviso_pedido_web on public.pedidos_web;
create trigger aviso_pedido_web after insert on public.pedidos_web
  for each row execute function public.aviso_pedido_web();
