-- Cuentas · avisos de Inversiones (precio de la acción o valor de la posición en €)
-- Requisitos: cuentas-push.sql ya ejecutado (cuentas_push_enviar) y la Edge Function cuentas-alertas desplegada.
-- Pégalo entero en Supabase > SQL Editor > Run. Se puede repetir sin problema.

create table if not exists public.cuentas_alertas (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null,                 -- cuentas_perfiles.id (el mismo que cuentas_data.user_id)
  inv_id text,                           -- inversión (null = favorito)
  symbol text not null,
  name text,
  cur text,
  kind text not null check (kind in ('precio','valor')),
  op text not null check (op in ('>=','<=')),
  target numeric not null check (target > 0),
  created_at timestamptz not null default now(),
  fired_at timestamptz,
  fired_value numeric
);
create index if not exists cuentas_alertas_pend on public.cuentas_alertas (fired_at) where fired_at is null;

-- perfiles del usuario conectado (sin depender de los permisos de cuentas_perfiles)
create or replace function public.cuentas_mis_perfiles()
returns setof uuid language sql stable security definer set search_path = public as $$
  select p.id from cuentas_perfiles p where p.auth_user_id = auth.uid()
$$;
revoke all on function public.cuentas_mis_perfiles() from public, anon;
grant execute on function public.cuentas_mis_perfiles() to authenticated;

alter table public.cuentas_alertas enable row level security;
drop policy if exists cuentas_alertas_propias on public.cuentas_alertas;
create policy cuentas_alertas_propias on public.cuentas_alertas for all to authenticated
  using (user_id in (select public.cuentas_mis_perfiles()))
  with check (user_id in (select public.cuentas_mis_perfiles()));
revoke all on public.cuentas_alertas from anon;
grant select, insert, update, delete on public.cuentas_alertas to authenticated;

-- Avisos sin disparar, con las participaciones que hay ahora (para los de valor)
create or replace function public.cuentas_alertas_pendientes()
returns table(id uuid, user_id uuid, inv_id text, symbol text, name text, cur text, kind text, op text, target numeric, units numeric)
language sql stable security definer set search_path = public as $$
  select a.id, a.user_id, a.inv_id, a.symbol, a.name, a.cur, a.kind, a.op, a.target,
    case when a.kind = 'valor' then (
      select coalesce((select sum((l->>'units')::numeric) from jsonb_array_elements(coalesce(x->'lots','[]'::jsonb)) l), 0)
           - coalesce((select sum((v->>'units')::numeric) from jsonb_array_elements(coalesce(x->'sales','[]'::jsonb)) v), 0)
        from cuentas_data d, jsonb_array_elements(coalesce(d.data->'investments','[]'::jsonb)) x
       where d.user_id = a.user_id and x->>'id' = a.inv_id
       limit 1)
    end
  from cuentas_alertas a
  where a.fired_at is null
$$;
revoke all on function public.cuentas_alertas_pendientes() from public, anon, authenticated;
grant execute on function public.cuentas_alertas_pendientes() to service_role;

-- Marca el aviso como hecho (una sola vez) y manda el push
create or replace function public.cuentas_alerta_disparar(p_id uuid, p_value numeric, p_title text, p_body text, p_url text)
returns void language plpgsql security definer set search_path = public as $$
declare u uuid;
begin
  update cuentas_alertas set fired_at = now(), fired_value = p_value
   where id = p_id and fired_at is null
   returning user_id into u;
  if u is null then return; end if;
  perform cuentas_push_enviar(u, p_title, p_body, p_url, 'alerta-' || p_id);
end $$;
revoke all on function public.cuentas_alerta_disparar(uuid, numeric, text, text, text) from public, anon, authenticated;
grant execute on function public.cuentas_alerta_disparar(uuid, numeric, text, text, text) to service_role;

-- Cada 10 minutos, pg_cron llama a la función cuentas-alertas
create extension if not exists pg_cron;
create extension if not exists pg_net;
do $$ begin
  if exists (select 1 from cron.job where jobname = 'cuentas-alertas') then perform cron.unschedule('cuentas-alertas'); end if;
end $$;
select cron.schedule('cuentas-alertas', '*/10 * * * *', $cron$
  select net.http_post(
    url := 'https://aysogafvoexxoosvahdj.supabase.co/functions/v1/cuentas-alertas',
    headers := jsonb_build_object('Content-Type', 'application/json',
      'Authorization', 'Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImF5c29nYWZ2b2V4eG9vc3ZhaGRqIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODQ2MjQwNDMsImV4cCI6MjEwMDIwMDA0M30.wccYP_Ejm_fpRJosCNKGMyOnnj0_xhOkRzcLImkzn28'),
    body := '{}'::jsonb)
$cron$);
