-- ============================================================
--  Belidai 18 · Avisos por Telegram al dueño
--  Te llega un mensaje en Telegram cuando:
--    • alguien carga un PAGO para aprobar (Carmen, Skarlet o un vendedor)
--    • alguien hace una NOTA DE CRÉDITO para aprobar
--
--  PASO A: Supabase → SQL Editor → New query → pega TODO este archivo → Run
--  PASO B: en otra query nueva, pega esta línea con TU token y TU número de Telegram → Run
--      select public.telegram_configurar('PEGA_AQUI_EL_TOKEN', 'PEGA_AQUI_TU_ID');
--  PASO C (prueba): select public.telegram_enviar('✅ Avisos de Belidai 18 activados');
--
--  El token NO queda guardado en GitHub: solo en tu base de datos.
--  Para apagar los avisos:  select public.telegram_configurar(null, null);
-- ============================================================

create extension if not exists pg_net;

create table if not exists public.avisos_config (
  id int primary key default 1 check (id = 1),
  token text,
  chat_id text
);
alter table public.avisos_config enable row level security;   -- nadie la lee desde el programa
revoke all on public.avisos_config from anon, authenticated;

create or replace function public.telegram_configurar(p_token text, p_chat text) returns text
language plpgsql security definer set search_path = public as $$
begin
  insert into public.avisos_config(id, token, chat_id) values (1, nullif(trim(p_token),''), nullif(trim(p_chat),''))
  on conflict (id) do update set token = excluded.token, chat_id = excluded.chat_id;
  return case when p_token is null then 'Avisos apagados' else 'Listo: avisos configurados' end;
end $$;
revoke all on function public.telegram_configurar(text, text) from public, anon, authenticated;

create or replace function public.telegram_enviar(p_texto text) returns void
language plpgsql security definer set search_path = public as $$
declare c record;
begin
  select token, chat_id into c from public.avisos_config where id = 1;
  if c.token is null or c.chat_id is null then return; end if;
  perform net.http_post(
    url     := 'https://api.telegram.org/bot' || c.token || '/sendMessage',
    body    := jsonb_build_object('chat_id', c.chat_id, 'text', p_texto, 'disable_web_page_preview', true),
    headers := '{"Content-Type":"application/json"}'::jsonb);
exception when others then
  null;  -- un aviso que falla nunca debe impedir que se guarde el pago
end $$;
revoke all on function public.telegram_enviar(text) from public, anon, authenticated;

create or replace function public.aviso_por_aprobar() returns trigger
language plpgsql security definer set search_path = public as $$
declare d jsonb := new.data; t text; quien text; met text; monto text;
begin
  -- solo cuando el registro entra nuevo como pendiente (no al editarlo después)
  if tg_op = 'UPDATE' and coalesce(old.data->>'estado','') = coalesce(d->>'estado','') then return new; end if;

  if new.col = 'pagosVend' and d->>'estado' = 'pendiente' then
    met := case d->>'metodo' when 'zelle' then 'Zelle' when 'efectivo' then 'Efectivo $' when 'binance' then 'Binance'
                              when 'usdt' then 'USDT' when 'bs' then 'Bolívares' else coalesce(d->>'metodo','') end;
    monto := '$' || to_char(coalesce((d->>'montoUSD')::numeric,0), 'FM999G999G990D00');
    if d->>'moneda' = 'Bs' then
      monto := monto || ' (Bs ' || to_char(coalesce((d->>'montoOriginal')::numeric,0), 'FM999G999G990D00')
                     || ' a ' || coalesce(d->>'tasa','') || ')';
    end if;
    quien := coalesce(nullif(d->>'reportadoPor',''), nullif(d->>'vendedor',''), nullif(d->>'email',''), '');
    t := '💰 Pago por aprobar' || chr(10)
      || coalesce(d->>'cliente','') || chr(10)
      || 'Nota ' || coalesce(nullif(d->>'numero',''),'—') || ' · ' || monto || ' · ' || met
      || case when coalesce(d->>'referencia','') <> '' then chr(10) || 'Ref. ' || (d->>'referencia') else '' end
      || case when quien <> '' then chr(10) || 'Cargado por ' || quien else '' end
      || chr(10) || 'https://distribuidorabelidai18-star.github.io/belidai18-/';
    perform public.telegram_enviar(t);

  elsif new.col = 'notasCredito' and d->>'estado' = 'pendiente' then
    quien := coalesce(nullif(d->>'creadoPor',''), '');
    t := '🧾 Nota de crédito por aprobar' || chr(10)
      || coalesce(d->>'cliente','') || chr(10)
      || 'NC ' || coalesce(d->>'numero','') || ' a la nota ' || coalesce(nullif(d->>'notaNumero',''),'—')
      || ' · $' || to_char(coalesce((d->>'montoUSD')::numeric,0), 'FM999G999G990D00')
      || case when quien <> '' then chr(10) || 'Hecha por ' || quien else '' end
      || chr(10) || 'https://distribuidorabelidai18-star.github.io/belidai18-/';
    perform public.telegram_enviar(t);
  end if;
  return new;
end $$;

drop trigger if exists aviso_por_aprobar on public.docs;
create trigger aviso_por_aprobar after insert or update on public.docs
  for each row when (new.col in ('pagosVend','notasCredito'))
  execute function public.aviso_por_aprobar();
