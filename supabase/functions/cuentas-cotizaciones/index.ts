// Cuentas · cotizaciones para la parte de Inversiones (fuente: Yahoo Finance, sin clave).
// Despliegue: Supabase > Edge Functions > Deploy a new function > Via Editor,
// nombre "cuentas-cotizaciones", pegar este archivo y Deploy. No necesita secrets.
//
// La app la llama con supabase.functions.invoke('cuentas-cotizaciones', { body }) y body:
//   { op:'search', q:'amazon' }                         -> { items:[{symbol,name,type,exch}] }
//   { op:'quotes', symbols:['AMZN','USDEUR=X'] }         -> { quotes:{ AMZN:{price,prev,cur,time,name} | null } }
//   { op:'chart',  symbol:'AMZN', from:'2025-01-01', interval:'1d'|'1wk' } -> { cur, t:[seg], c:[cierre] }

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const HOSTS = ['https://query2.finance.yahoo.com', 'https://query1.finance.yahoo.com'];
const TYPES = new Set(['EQUITY', 'ETF', 'MUTUALFUND', 'CRYPTOCURRENCY']);
const SYM = /^[A-Za-z0-9.\-=^]{1,25}$/;

const cache = new Map<string, { until: number; v: unknown }>();
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

async function yget(path: string, ttlMs: number): Promise<any> {
  const hit = cache.get(path);
  if (hit && hit.until > Date.now()) return hit.v;
  let last = '';
  for (let i = 0; i < 4; i++) {
    try {
      const r = await fetch(HOSTS[i % 2] + path, { headers: { 'User-Agent': 'Cuentas/1.0', Accept: 'application/json' } });
      if (r.ok) {
        const v = await r.json();
        cache.set(path, { until: Date.now() + ttlMs, v });
        if (cache.size > 500) cache.delete(cache.keys().next().value!);
        return v;
      }
      last = 'HTTP ' + r.status;
      if (r.status === 404) break;
    } catch (e) { last = String(e); }
    await sleep(350 * (i + 1));
  }
  if (hit) return hit.v; // mejor un dato algo viejo que nada
  throw new Error('Sin cotización (' + last + ')');
}

const json = (b: unknown, status = 200) =>
  new Response(JSON.stringify(b), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });

async function quote(s: string) {
  const j = await yget(`/v8/finance/chart/${encodeURIComponent(s)}?range=1d&interval=1d`, 60_000);
  const m = j?.chart?.result?.[0]?.meta;
  if (!m || typeof m.regularMarketPrice !== 'number') return null;
  return {
    price: m.regularMarketPrice,
    prev: m.chartPreviousClose ?? m.previousClose ?? null,
    cur: m.currency || '',
    time: m.regularMarketTime || null,
    name: m.longName || m.shortName || s,
  };
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  try {
    const b = await req.json().catch(() => ({}));

    if (b.op === 'search') {
      const q = String(b.q || '').trim().slice(0, 60);
      if (q.length < 2) return json({ items: [] });
      const j = await yget(`/v1/finance/search?q=${encodeURIComponent(q)}&quotesCount=15&newsCount=0&listsCount=0`, 3_600_000);
      const items = (j.quotes || [])
        .filter((x: any) => TYPES.has(x.quoteType) && x.symbol)
        .map((x: any) => ({ symbol: x.symbol, name: x.longname || x.shortname || x.symbol, type: x.quoteType, exch: x.exchDisp || x.exchange || '' }));
      return json({ items });
    }

    if (b.op === 'quotes') {
      const syms = [...new Set((Array.isArray(b.symbols) ? b.symbols : []).map(String))].filter((s) => SYM.test(s)).slice(0, 40);
      const out = await Promise.all(syms.map(async (s) => [s, await quote(s).catch(() => null)] as const));
      return json({ quotes: Object.fromEntries(out) });
    }

    if (b.op === 'chart') {
      const s = String(b.symbol || '');
      if (!SYM.test(s)) return json({ error: 'Símbolo no válido' }, 400);
      const from = /^\d{4}-\d{2}-\d{2}$/.test(b.from || '') ? Date.parse(b.from + 'T00:00:00Z') / 1000 : Date.now() / 1000 - 365 * 86400;
      const p1 = Math.floor(from), p2 = Math.ceil(Date.now() / 3_600_000) * 3600; // redondeado a la hora para aprovechar la caché
      const interval = b.interval === '1wk' ? '1wk' : '1d';
      const j = await yget(`/v8/finance/chart/${encodeURIComponent(s)}?period1=${p1}&period2=${p2}&interval=${interval}`, 3 * 3_600_000);
      const r = j?.chart?.result?.[0];
      if (!r) return json({ error: 'Sin histórico' }, 404);
      const ts: number[] = r.timestamp || [], cl: (number | null)[] = r.indicators?.quote?.[0]?.close || [];
      const t: number[] = [], c: number[] = [];
      ts.forEach((x, i) => { const v = cl[i]; if (typeof v === 'number' && isFinite(v)) { t.push(x); c.push(v); } });
      return json({ cur: r.meta?.currency || '', t, c });
    }

    return json({ error: 'Operación no válida' }, 400);
  } catch (e) {
    return json({ error: String((e as Error).message || e) }, 502);
  }
});
