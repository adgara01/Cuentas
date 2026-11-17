// Cuentas · comprueba los avisos de Inversiones (precio o valor de la posición) y manda el push.
// La llama pg_cron cada 10 minutos (ver supabase/cuentas-alertas.sql). No necesita secrets propios:
// usa SUPABASE_URL y SUPABASE_SERVICE_ROLE_KEY, que Supabase pone solas en todas las funciones.
import { createClient } from 'npm:@supabase/supabase-js@2';

const db = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
const HOSTS = ['https://query2.finance.yahoo.com', 'https://query1.finance.yahoo.com'];
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
const pence = (c: string) => c === 'GBp' || c === 'GBX' || c === 'ILA';
const fxSym = (c: string) => (c === 'GBp' || c === 'GBX' ? 'GBPEUR=X' : c === 'ILA' ? 'ILSEUR=X' : c + 'EUR=X');
const num = (n: number, d = 2) => n.toLocaleString('es-ES', { minimumFractionDigits: d, maximumFractionDigits: d });
const px = (n: number, c: string) => num(n, n < 1 ? 4 : 2) + ' ' + (c === 'EUR' ? '€' : c === 'USD' ? '$' : c);

async function price(s: string): Promise<{ price: number; cur: string } | null> {
  for (let i = 0; i < 4; i++) {
    try {
      const r = await fetch(`${HOSTS[i % 2]}/v8/finance/chart/${encodeURIComponent(s)}?range=1d&interval=1d`, { headers: { 'User-Agent': 'Cuentas/1.0', Accept: 'application/json' } });
      if (r.ok) {
        const m = (await r.json())?.chart?.result?.[0]?.meta;
        return m && typeof m.regularMarketPrice === 'number' ? { price: m.regularMarketPrice, cur: m.currency || '' } : null;
      }
      if (r.status === 404) return null;
    } catch (_) { /* reintenta */ }
    await sleep(400 * (i + 1));
  }
  return null;
}

const json = (b: unknown, status = 200) => new Response(JSON.stringify(b), { status, headers: { 'Content-Type': 'application/json' } });

Deno.serve(async () => {
  const { data: al, error } = await db.rpc('cuentas_alertas_pendientes');
  if (error) return json({ error: error.message }, 500);
  if (!al || !al.length) return json({ pendientes: 0 });
  const syms = new Set<string>();
  for (const a of al) { syms.add(a.symbol); if (a.kind === 'valor' && a.cur && a.cur !== 'EUR') syms.add(fxSym(a.cur)); }
  const q: Record<string, { price: number; cur: string } | null> = {};
  await Promise.all([...syms].map(async (s) => { q[s] = await price(s); }));
  let fired = 0;
  for (const a of al) {
    const p = q[a.symbol]; if (!p) continue;
    const cur = a.cur || p.cur;
    let v = p.price, title = '', body = '';
    if (a.kind === 'valor') {
      let fx = 1;
      if (cur && cur !== 'EUR') { const f = q[fxSym(cur)]; if (!f) continue; fx = f.price * (pence(cur) ? 0.01 : 1); }
      v = Number(a.units || 0) * p.price * fx;
    }
    const hit = a.op === '>=' ? v >= Number(a.target) : v <= Number(a.target);
    if (!hit) continue;
    const name = a.name || a.symbol;
    if (a.kind === 'valor') { title = `${name} · ${num(v)} €`; body = `Tu posición ${a.op === '>=' ? 'ha subido' : 'ha bajado'} a ${num(v)} € (aviso en ${num(Number(a.target))} €)`; }
    else { title = `${name} · ${px(v, cur)}`; body = `${a.op === '>=' ? 'Ha subido' : 'Ha bajado'} a ${px(v, cur)} (aviso en ${px(Number(a.target), cur)})`; }
    const url = a.inv_id ? './#inv=' + a.inv_id : './#fav=' + a.symbol;
    const r = await db.rpc('cuentas_alerta_disparar', { p_id: a.id, p_value: v, p_title: title, p_body: body, p_url: url });
    if (!r.error) fired++;
  }
  return json({ pendientes: al.length, avisados: fired });
});
