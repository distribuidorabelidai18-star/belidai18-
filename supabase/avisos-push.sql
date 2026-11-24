-- ============================================================
--  Belidai 18 · Avisos en el teléfono del dueño (notificaciones del programa)
--  Avisa cuando alguien carga un PAGO o una NOTA DE CRÉDITO para aprobar.
--
--  Supabase → SQL Editor → New query → pegar TODO → Run.
--  Las claves secretas NO están aquí: se ponen aparte con push_configurar(...)
-- ============================================================

create extension if not exists pg_net;

-- Claves de los avisos (solo las lee la función del servidor)
create table if not exists public.avisos_config (id int primary key default 1 check (id = 1));
alter table public.avisos_config add column if not exists vapid_pub  text;
alter table public.avisos_config add column if not exists vapid_priv text;
alter table public.avisos_config add column if not exists push_clave text;
alter table public.avisos_config enable row level security;
revoke all on public.avisos_config from anon, authenticated;

create or replace function public.push_configurar(p_pub text, p_priv text, p_clave text) returns text
language plpgsql security definer set search_path = public as $$
begin
  insert into public.avisos_config(id, vapid_pub, vapid_priv, push_clave) values (1, p_pub, p_priv, p_clave)
  on conflict (id) do update set vapid_pub = excluded.vapid_pub, vapid_priv = excluded.vapid_priv, push_clave = excluded.push_clave;
  return 'Listo: claves de avisos guardadas';
end $$;
revoke all on function public.push_configurar(text, text, text) from public, anon, authenticated;

-- Teléfonos del dueño que activaron los avisos
create table if not exists public.push_subs (
  endpoint text primary key,
  sub      jsonb not null,
  email    text,
  creado   timestamptz default now()
);
alter table public.push_subs enable row level security;
drop policy if exists "dueno_push" on public.push_subs;
create policy "dueno_push" on public.push_subs for all to authenticated
  using (public.mi_rol() = 'dueno') with check (public.mi_rol() = 'dueno');

-- Manda un aviso a los teléfonos (llama a la función avisar-push)
create or replace function public.push_enviar(p_titulo text, p_texto text, p_tag text default null) returns void
language plpgsql security definer set search_path = public as $$
declare c record;
begin
  select push_clave into c from public.avisos_config where id = 1;
  if c.push_clave is null then return; end if;
  perform net.http_post(
    url     := 'https://iwuhgtshyospffaulenb.supabase.co/functions/v1/avisar-push',
    body    := jsonb_build_object('titulo', p_titulo, 'texto', p_texto, 'tag', p_tag,
                                  'url', 'https://distribuidorabelidai18-star.github.io/belidai18-/'),
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-aviso-clave', c.push_clave));
exception when others then
  null;  -- un aviso que falla nunca impide guardar el pago
end $$;
revoke all on function public.push_enviar(text, text, text) from public, anon, authenticated;

create or replace function public.aviso_por_aprobar() returns trigger
language plpgsql security definer set search_path = public as $$
declare d jsonb := new.data; quien text; met text; monto text;
begin
  -- solo cuando entra como pendiente (no cada vez que se vuelve a guardar)
  if tg_op = 'UPDATE' and coalesce(old.data->>'estado','') = coalesce(d->>'estado','') then return new; end if;

  if new.col = 'pagosVend' and d->>'estado' = 'pendiente' then
    met := case d->>'metodo' when 'zelle' then 'Zelle' when 'efectivo' then 'Efectivo $' when 'binance' then 'Binance'
                              when 'usdt' then 'USDT' when 'bs' then 'Bolívares' else coalesce(d->>'metodo','') end;
    monto := '$' || to_char(coalesce((d->>'montoUSD')::numeric,0), 'FM999G999G990D00');
    if d->>'moneda' = 'Bs' then
      monto := monto || ' (Bs ' || to_char(coalesce((d->>'montoOriginal')::numeric,0), 'FM999G999G990D00') || ')';
    end if;
    quien := coalesce(nullif(d->>'reportadoPor',''), nullif(d->>'vendedor',''), '');
    perform public.push_enviar(
      '💰 Pago por aprobar · ' || monto,
      coalesce(d->>'cliente','') || ' · Nota ' || coalesce(nullif(d->>'numero',''),'—') || ' · ' || met
        || case when quien <> '' then chr(10) || 'Cargado por ' || quien else '' end,
      'pv-' || new.id);

  elsif new.col = 'notasCredito' and d->>'estado' = 'pendiente' then
    quien := coalesce(nullif(d->>'creadoPor',''), '');
    perform public.push_enviar(
      '🧾 Nota de crédito por aprobar · $' || to_char(coalesce((d->>'montoUSD')::numeric,0), 'FM999G999G990D00'),
      coalesce(d->>'cliente','') || ' · NC ' || coalesce(d->>'numero','') || ' a la nota ' || coalesce(nullif(d->>'notaNumero',''),'—')
        || case when quien <> '' then chr(10) || 'Hecha por ' || quien else '' end,
      'nc-' || new.id);
  end if;
  return new;
end $$;

drop trigger if exists aviso_por_aprobar on public.docs;
create trigger aviso_por_aprobar after insert or update on public.docs
  for each row when (new.col in ('pagosVend','notasCredito'))
  execute function public.aviso_por_aprobar();
