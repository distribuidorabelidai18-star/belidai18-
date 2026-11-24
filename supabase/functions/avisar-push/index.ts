// Belidai 18 · Función "avisar-push" (Supabase → Edge Functions)
// La llama la base de datos cuando entra un pago o una nota de crédito por aprobar,
// y manda la notificación a los teléfonos del dueño que activaron los avisos.
import webpush from "npm:web-push@3.6.7";
import { createClient } from "npm:@supabase/supabase-js@2";

Deno.serve(async (req) => {
  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const { data: cfg } = await sb.from("avisos_config").select("vapid_pub,vapid_priv,push_clave").eq("id", 1).maybeSingle();
  if (!cfg?.push_clave || req.headers.get("x-aviso-clave") !== cfg.push_clave) {
    return new Response("no autorizado", { status: 401 });
  }
  const { titulo, texto, url, tag } = await req.json().catch(() => ({}));
  webpush.setVapidDetails("https://distribuidorabelidai18-star.github.io", cfg.vapid_pub, cfg.vapid_priv);

  const { data: subs } = await sb.from("push_subs").select("endpoint,sub");
  let enviados = 0, errores = 0;
  for (const s of subs ?? []) {
    try {
      await webpush.sendNotification(s.sub, JSON.stringify({ titulo, texto, url, tag }), { TTL: 86400, urgency: "high" });
      enviados++;
    } catch (e) {
      errores++;
      const code = (e as { statusCode?: number })?.statusCode;
      if (code === 404 || code === 410) await sb.from("push_subs").delete().eq("endpoint", s.endpoint); // teléfono que ya no existe
      console.error("push", code, String(e));
    }
  }
  return new Response(JSON.stringify({ enviados, errores }), { headers: { "content-type": "application/json" } });
});
