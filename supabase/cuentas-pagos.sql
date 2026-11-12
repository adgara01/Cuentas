-- Cuentas · pagos con Apple Pay (Atajo "Cartera" de iOS) · aviso push con cuenta y categoría
-- Aviso (nov 2026): título "−1,70 € · Rest/Bar" y texto "Ticket Rest. · comercio" (iOS añade "from Cuentas").
-- Ejecuta ANTES cuentas-push.sql (define cuentas_push_enviar y cuentas_eur).
-- Pégalo entero en Supabase > SQL Editor > Run. Se puede repetir sin problema.
-- Novedades:
--   p_ref   identificador del pago que pone el Atajo: si ya entró, no se apunta otra vez.
--   p_fecha "yyyy-MM-dd HH:mm:ss" (hora de España) del momento del pago: si llega tarde desde la cola, se apunta con su fecha real.
--   Toda respuesta del servidor lleva "cola":"borrar" -> el Atajo borra el archivo de la cola.
--   Los Atajos antiguos (sin p_ref ni p_fecha) siguen funcionando igual.

create or replace function public.cuentas_norm(t text)
returns text language sql immutable set search_path = public as $$
  select btrim(regexp_replace(regexp_replace(
    translate(lower(coalesce(t,'')), 'áàäâéèëêíìïîóòöôúùüûñç', 'aaaaeeeeiiiioooouuuunc'),
    '[^a-z ]', ' ', 'g'), '\s+', ' ', 'g'))
$$;

-- Registro de lo que llega desde el Atajo (sirve para ver por qué falla algo).
create table if not exists public.cuentas_pagos_log (
  id bigserial primary key,
  at timestamptz not null default now(),
  importe text, comercio text, tarjeta text, resultado text
);
alter table public.cuentas_pagos_log add column if not exists ref text;
alter table public.cuentas_pagos_log add column if not exists fecha text;
create index if not exists cuentas_pagos_log_ref on public.cuentas_pagos_log(ref) where ref is not null;
alter table public.cuentas_pagos_log enable row level security;
revoke all on public.cuentas_pagos_log from anon, authenticated;

-- Versiones anteriores (otros parámetros): se borran para no tener dos funciones.
drop function if exists public.cuentas_add_pago(text,numeric,text,text);
drop function if exists public.cuentas_add_pago(text,text,text,text);

create or replace function public.cuentas_add_pago(
  p_code text, p_importe text, p_comercio text, p_tarjeta text default '',
  p_ref text default '', p_fecha text default ''
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  logid bigint; res jsonb; ref_ text := nullif(btrim(coalesce(p_ref,'')), '');
  uid_ uuid; d jsonb; ms bigint; pay_ms bigint; pay_at timestamptz; imp numeric; mn text; cn text; s text;
  acc text; cat text; rule text; pend boolean := false; acc_guess boolean := false; tx jsonb;
  tid text; acc_name text; cat_known boolean := false; txt text; ttl text; com text;
begin
  insert into cuentas_pagos_log(importe, comercio, tarjeta, ref, fecha, resultado)
    values (p_importe, p_comercio, p_tarjeta, ref_, nullif(p_fecha,''), 'recibido') returning id into logid;

  begin
    -- importe: acepta "1,50", "1.50", "1,50 €", "€1,50", "1.234,56 €"...
    s := regexp_replace(coalesce(p_importe,''), '[^0-9,.]', '', 'g');
    if position(',' in s) > 0 then s := replace(replace(s, '.', ''), ',', '.'); end if;
    if s = '' then raise exception 'Importe vacío'; end if;
    imp := abs(s::numeric);
    if imp = 0 then raise exception 'Importe no válido'; end if;

    select ca.user_id into uid_ from cuentas_atajo ca where ca.token = p_code;
    if uid_ is null then raise exception 'Clave del atajo no válida'; end if;
    select data into d from cuentas_data where user_id = uid_ for update;
    if d is null then raise exception 'Aún no hay datos en esta cuenta'; end if;

    -- mismo identificador ya apuntado (reenvío desde la cola): no se repite
    if ref_ is not null and exists (
      select 1 from cuentas_pagos_log l where l.ref = ref_ and l.id <> logid and l.resultado like 'ok%'
    ) then
      update cuentas_pagos_log set resultado = 'repetido (ref), ignorado' where id = logid;
      return jsonb_build_object('ok', true, 'mensaje', 'Pago repetido, ignorado', 'cola', 'borrar');
    end if;

    ms := (extract(epoch from clock_timestamp()) * 1000)::bigint;

    -- fecha real del pago (si viene y es razonable: últimos 60 días, no en el futuro)
    begin
      if coalesce(p_fecha,'') <> '' then
        pay_at := (replace(p_fecha,'T',' ')::timestamp) at time zone 'Europe/Madrid';
        if pay_at > now() + interval '10 minutes' or pay_at < now() - interval '60 days' then pay_at := null; end if;
      end if;
    exception when others then pay_at := null;
    end;
    pay_ms := coalesce((extract(epoch from pay_at) * 1000)::bigint, ms);

    -- sin identificador (Atajo antiguo): mismo pago en menos de 2 minutos = repetido
    if ref_ is null and exists (
      select 1 from jsonb_array_elements(coalesce(d->'transactions','[]'::jsonb)) t
       where t->>'src' = 'applepay' and coalesce(t->>'merchantRaw','') = coalesce(p_comercio,'')
         and (t->>'amount')::numeric = imp and coalesce(t->>'card','') = coalesce(p_tarjeta,'')
         and coalesce((t->>'ts')::bigint,0) > ms - 120000
    ) then
      update cuentas_pagos_log set resultado = 'repetido, ignorado' where id = logid;
      return jsonb_build_object('ok', true, 'mensaje', 'Pago repetido, ignorado', 'cola', 'borrar');
    end if;

    mn := cuentas_norm(p_comercio);
    cn := cuentas_norm(p_tarjeta);

    acc := d->'cardMap'->>cn;
    if acc is null or not exists (select 1 from jsonb_array_elements(d->'accounts') a where a->>'id' = acc) then
      select a->>'id' into acc from jsonb_array_elements(d->'accounts') a
       where a->>'type' = 'corriente' and coalesce((a->>'manual')::boolean,false) = false limit 1;
      acc_guess := true; pend := true;
    end if;
    if acc is null then raise exception 'No hay ninguna cuenta corriente'; end if;

    rule := d->'merchantRules'->>mn;
    if rule is not null and exists (select 1 from jsonb_array_elements_text(d->'categories') c where c = rule) then
      cat := rule; cat_known := true;
    else
      cat := 'Sin categorizar'; pend := true;
    end if;

    tid := to_char(ms,'FM999999999999999') || substr(md5(random()::text),1,5);
    tx := jsonb_build_object(
      'id', tid,
      'type', 'Gasto', 'account', acc, 'category', cat, 'amount', imp,
      'comment', left(coalesce(nullif(d->'merchantNotes'->>mn,''), p_comercio, ''), 60),
      'date', to_char(to_timestamp(pay_ms/1000.0) at time zone 'Europe/Madrid','YYYY-MM-DD'),
      'src', 'applepay', 'merchant', mn, 'merchantRaw', coalesce(p_comercio,''),
      'card', coalesce(p_tarjeta,''), 'ts', pay_ms
    );
    if ref_ is not null then tx := tx || jsonb_build_object('ref', ref_); end if;
    if pend then tx := tx || jsonb_build_object('pending', true); else tx := tx || jsonb_build_object('auto', true); end if;
    if acc_guess then tx := tx || jsonb_build_object('acctGuess', true); end if;

    d := jsonb_set(d, '{transactions}', coalesce(d->'transactions','[]'::jsonb) || tx);
    d := jsonb_set(d, '{_updatedAt}', to_jsonb(ms));
    update cuentas_data set data = d, updated_at = to_timestamp(ms/1000.0) where user_id = uid_;

    -- aviso al iPhone (si falla, no pasa nada: el pago ya está guardado)
    -- El título ya es la información (importe y categoría): iOS añade debajo "from Cuentas"
    -- por su cuenta, así que si el título fuera "Cuentas" saldría el nombre dos veces.
    begin
      select a->>'name' into acc_name from jsonb_array_elements(d->'accounts') a where a->>'id' = acc limit 1;
      com := nullif(btrim(left(coalesce(nullif(d->'merchantNotes'->>mn,''), p_comercio, ''), 40)), '');
      ttl := '−' || cuentas_eur(imp) || ' €';
      if cat_known and not acc_guess then
        ttl := ttl || ' · ' || cat;
        txt := coalesce(acc_name,'—') || coalesce(' · ' || com, '');
        perform cuentas_push_enviar(uid_, ttl, txt, './#mov=' || tid, 'tx-' || tid);
      elsif cat_known then
        ttl := ttl || ' · ' || cat;
        txt := coalesce(com || ' · ', '') || 'Falta confirmar la cuenta';
        perform cuentas_push_enviar(uid_, ttl, txt, './#pend=' || tid, 'tx-' || tid);
      else
        ttl := ttl || coalesce(' · ' || com, '');
        txt := 'Pendiente de categorizar';
        perform cuentas_push_enviar(uid_, ttl, txt, './#pend=' || tid, 'tx-' || tid);
      end if;
    exception when others then null;
    end;

    res := jsonb_build_object('ok', true, 'cola', 'borrar', 'mensaje',
      case when pend then 'Pago de '||imp||'€ apuntado (por confirmar)' else 'Pago de '||imp||'€ en '||cat end);
    update cuentas_pagos_log set resultado = 'ok: ' || (res->>'mensaje') where id = logid;
    return res;
  exception when others then
    update cuentas_pagos_log set resultado = 'ERROR: ' || sqlerrm where id = logid;
    return jsonb_build_object('ok', false, 'error', sqlerrm, 'cola', 'borrar');
  end;
end $$;

revoke all on function public.cuentas_add_pago(text,text,text,text,text,text) from public;
grant execute on function public.cuentas_add_pago(text,text,text,text,text,text) to anon;

notify pgrst, 'reload schema';
