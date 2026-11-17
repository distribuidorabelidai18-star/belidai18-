-- ============================================================
--  Belidai 18 · Acceso para vendedores (correr UNA vez)
--  Supabase → SQL Editor → New query → pegar todo → Run
--  No cambia lo que ya pueden hacer el dueño y la ayudante:
--  solo agrega límites para los usuarios con rol 'vendedor'.
-- ============================================================

-- 1) Cada perfil de vendedor dice qué vendedor es (como sale en las notas, ej. SKARLET)
alter table public.perfiles add column if not exists vendedor text;

-- 2) Funciones de ayuda
create or replace function public.mi_rol() returns text
language sql stable security definer set search_path = public as $$
  select rol from public.perfiles where lower(email) = lower(auth.jwt()->>'email') limit 1
$$;

create or replace function public.mi_vendedor() returns text
language sql stable security definer set search_path = public as $$
  select upper(trim(vendedor)) from public.perfiles where lower(email) = lower(auth.jwt()->>'email') limit 1
$$;

-- Lo que un vendedor puede ver: productos, SUS notas, los abonos de SUS notas y SUS pagos reportados
create or replace function public.vend_puede_ver(c text, d jsonb) returns boolean
language sql stable security definer set search_path = public as $$
  select case
    when c = 'productos' then true
    when c = 'facturas'  then upper(trim(d->>'vendedor')) = public.mi_vendedor()
    when c = 'abonos'    then exists (select 1 from public.docs f
                                      where f.col = 'facturas' and f.id = d->>'facturaId'
                                        and upper(trim(f.data->>'vendedor')) = public.mi_vendedor())
    when c = 'pagosVend' then lower(d->>'email') = lower(auth.jwt()->>'email')
    else false
  end
$$;

create or replace function public.vend_puede_reportar(c text, d jsonb) returns boolean
language sql stable security definer set search_path = public as $$
  select c = 'pagosVend'
     and lower(d->>'email') = lower(auth.jwt()->>'email')
     and d->>'estado' = 'pendiente'
     and public.vend_puede_ver('facturas', (select f.data from public.docs f where f.col = 'facturas' and f.id = d->>'facturaId'))
$$;

-- 3) Tabla docs: permisos del vendedor
drop policy if exists "vendedor_lee"     on public.docs;
drop policy if exists "vendedor_reporta" on public.docs;
drop policy if exists "vendedor_corrige" on public.docs;
create policy "vendedor_lee" on public.docs for select to authenticated
  using (public.mi_rol() = 'vendedor' and public.vend_puede_ver(col, data));
create policy "vendedor_reporta" on public.docs for insert to authenticated
  with check (public.mi_rol() = 'vendedor' and public.vend_puede_reportar(col, data));
create policy "vendedor_corrige" on public.docs for update to authenticated
  using (public.mi_rol() = 'vendedor' and public.vend_puede_reportar(col, data))
  with check (public.mi_rol() = 'vendedor' and public.vend_puede_reportar(col, data));

-- Límites (restrictivos): aunque otra regla lo permita, un vendedor NUNCA pasa de aquí
drop policy if exists "limite_vendedor_ver"      on public.docs;
drop policy if exists "limite_vendedor_crear"    on public.docs;
drop policy if exists "limite_vendedor_cambiar"  on public.docs;
drop policy if exists "limite_vendedor_borrar"   on public.docs;
create policy "limite_vendedor_ver" on public.docs as restrictive for select to authenticated
  using (coalesce(public.mi_rol(), '') <> 'vendedor' or public.vend_puede_ver(col, data));
create policy "limite_vendedor_crear" on public.docs as restrictive for insert to authenticated
  with check (coalesce(public.mi_rol(), '') <> 'vendedor' or public.vend_puede_reportar(col, data));
create policy "limite_vendedor_cambiar" on public.docs as restrictive for update to authenticated
  using (coalesce(public.mi_rol(), '') <> 'vendedor' or public.vend_puede_reportar(col, data))
  with check (coalesce(public.mi_rol(), '') <> 'vendedor' or public.vend_puede_reportar(col, data));
create policy "limite_vendedor_borrar" on public.docs as restrictive for delete to authenticated
  using (coalesce(public.mi_rol(), '') <> 'vendedor');

-- 4) Fotos: el vendedor puede subir comprobantes, pero no borrar ni cambiar fotos
drop policy if exists "vendedor_sube_comprobante" on storage.objects;
drop policy if exists "limite_vendedor_fotos_cambiar" on storage.objects;
drop policy if exists "limite_vendedor_fotos_borrar"  on storage.objects;
create policy "vendedor_sube_comprobante" on storage.objects for insert to authenticated
  with check (bucket_id = 'fotos' and public.mi_rol() = 'vendedor');
create policy "limite_vendedor_fotos_cambiar" on storage.objects as restrictive for update to authenticated
  using (coalesce(public.mi_rol(), '') <> 'vendedor');
create policy "limite_vendedor_fotos_borrar" on storage.objects as restrictive for delete to authenticated
  using (coalesce(public.mi_rol(), '') <> 'vendedor');

-- 5) Perfiles: un vendedor no puede cambiarse el rol ni tocar perfiles
drop policy if exists "limite_vendedor_perfiles_crear"   on public.perfiles;
drop policy if exists "limite_vendedor_perfiles_cambiar" on public.perfiles;
drop policy if exists "limite_vendedor_perfiles_borrar"  on public.perfiles;
create policy "limite_vendedor_perfiles_crear" on public.perfiles as restrictive for insert to authenticated
  with check (coalesce(public.mi_rol(), '') <> 'vendedor');
create policy "limite_vendedor_perfiles_cambiar" on public.perfiles as restrictive for update to authenticated
  using (coalesce(public.mi_rol(), '') <> 'vendedor');
create policy "limite_vendedor_perfiles_borrar" on public.perfiles as restrictive for delete to authenticated
  using (coalesce(public.mi_rol(), '') <> 'vendedor');

-- 6) Comprobación: las dos filas deben decir "true" en seguridad_activa.
select relname as tabla, relrowsecurity as seguridad_activa
from pg_class where relname in ('docs','perfiles') and relnamespace = 'public'::regnamespace;
