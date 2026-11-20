-- ============================================================
--  Belidai 18 · Permisos para Carmen y Skarlet (rol de ayudante)
--  Supabase → SQL Editor → New query → pegar todo → Run
--  Les deja GUARDAR y CAMBIAR datos del programa (notas, pagos por
--  aprobar, notas de crédito, pedidos, cotizaciones, inventario,
--  fotos), pero NO BORRAR nada ni tocar la parte privada del dueño
--  (proveedores, cuentas por pagar, empleados, comisiones).
--  No cambia nada del dueño ni de los vendedores.
-- ============================================================

create or replace function public.mi_rol() returns text
language sql stable security definer set search_path = public as $$
  select rol from public.perfiles where lower(email) = lower(auth.jwt()->>'email') limit 1
$$;

-- Quién es ayudante: tiene perfil y no es dueño ni vendedor
create or replace function public.es_ayudante() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(public.mi_rol() not in ('dueno','vendedor'), false)
$$;

-- Datos del programa (tabla docs)
drop policy if exists "ayudante_guarda"  on public.docs;
drop policy if exists "ayudante_cambia"  on public.docs;
create policy "ayudante_guarda" on public.docs for insert to authenticated
  with check (public.es_ayudante() and col <> 'privado');
create policy "ayudante_cambia" on public.docs for update to authenticated
  using (public.es_ayudante() and col <> 'privado')
  with check (public.es_ayudante() and col <> 'privado');

-- Fotos (comprobantes de pago y la lista para la página de pedidos)
drop policy if exists "ayudante_ve_fotos"      on storage.objects;
drop policy if exists "ayudante_sube_fotos"    on storage.objects;
drop policy if exists "ayudante_cambia_fotos"  on storage.objects;
create policy "ayudante_ve_fotos" on storage.objects for select to authenticated
  using (bucket_id = 'fotos' and public.es_ayudante());
create policy "ayudante_sube_fotos" on storage.objects for insert to authenticated
  with check (bucket_id = 'fotos' and public.es_ayudante());
create policy "ayudante_cambia_fotos" on storage.objects for update to authenticated
  using (bucket_id = 'fotos' and public.es_ayudante())
  with check (bucket_id = 'fotos' and public.es_ayudante());
