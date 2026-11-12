# Cuentas

PWA de finanzas personales de Adri, en castellano. Un solo `index.html` (JS puro, localStorage + Supabase), publicada con GitHub Pages en https://adgara01.github.io/Cuentas/ desde la rama `main`.

## Cómo trabajar aquí

- Respuestas cortas, directas, en castellano; pasos exactos, de uno en uno.
- Subir `APP_VERSION` (formato `AAAA.MM.DD-N`) en cada entrega de `index.html`. La app compara su versión con la publicada para avisar de actualizaciones.
- Probar con Playwright antes de subir. Subir a `main` (y a la rama de trabajo) cuando Adri lo pida.
- Enseñar capturas antes de subir iconos o diseños nuevos.
- El repo es público: nunca claves privadas en el repo ni en el chat. En los SQL los secretos van como `<SECRETO>`.
- SQL para Supabase: darlo en bloque listo para copiar y pegar en el SQL Editor, probado antes en un Postgres 16 local con stubs.

## Estilo visual

Iconos de línea grises, sin emojis; sin textos explicativos tipo IA; esquinas concéntricas; sin cursor parpadeante; desplegables legibles en PC. Diseños con variables CSS (Flow por defecto; Clásico, Google, Wall Street 1870, Cámara acorazada) y color de acento elegible. El CSS de los diseños va entre `/*DESIGNS-START*/` y `/*DESIGNS-END*/`.

## Piezas

- `index.html`: toda la app (onboarding, login, bloqueo PIN + Face ID, Resumen, Insertar, Pendientes, Dashboard, Año, Movimientos, Objetivos, Ajustes, versión ordenador ≥1000px, atajos de teclado).
- `sw.js`: service worker solo para avisos push (sin caché).
- `manifest.json` + iconos (banco gris-dorado con €).
- `supabase/`: SQL que se ejecuta a mano en Supabase → SQL Editor.

## Supabase (proyecto `aysogafvoexxoosvahdj`)

- Tablas: `cuentas_data` (JSON de cada usuario), `cuentas_perfiles`, `cuentas_atajo` (clave `ck_…` del Atajo), `cuentas_pagos_log` (registro de lo que llega del Atajo), `cuentas_push_subs`.
- RPC: `cuentas_add_pago` (Atajo de Apple Pay), `cuentas_add_mov`, `cuentas_atajo_token`, `cuentas_cambiar_usuario`, `cuentas_username_taken`, `cuentas_reclamar_antiguo`, `cuentas_push_guardar/borrar`, `cuentas_push_enviar`, `cuentas_eur`, `cuentas_norm`.
- Edge Function `cuentas-push` (envía Web Push). Secrets: `VAPID_PUBLIC_KEY`, `VAPID_PRIVATE_KEY`, `VAPID_SUBJECT`, `WEBHOOK_SECRET`.
- `cuentas_push_enviar` llama a la Edge Function con pg_net y la cabecera `x-webhook-secret`, que debe ser igual a `WEBHOOK_SECRET`. Si no coincide, la función responde 401 y no llega el aviso. Para cambiarlo sin ver la función: `replace(pg_get_functiondef('public.cuentas_push_enviar'::regproc), '<valor viejo>', '<nuevo>')` y `execute`.
- Diagnóstico: `select at, importe, comercio, resultado from cuentas_pagos_log order by at desc limit 5;` y `select created, status_code, left(content::text,200) from net._http_response order by created desc limit 5;`

## Atajo de Apple Pay (iPhone)

- Una sola automatización de **Cartera** (3 tarjetas, todas las categorías, Ejecutar inmediatamente, Notificar activado) con una sola acción: Obtener contenido de URL → POST a `/rest/v1/rpc/cuentas_add_pago`, cabeceras `apikey`, `Authorization: Bearer <anon>`, `Content-Type: application/json`; cuerpo JSON `p_code`, `p_importe`, `p_comercio`, `p_tarjeta`.
- Tener dos automatizaciones a la vez hacía fallar el atajo ("Ha habido un problema al ejecutar la automatización"). Con una sola funciona.
- El botón ▶ deja una fila "Importe vacío": es normal.
- `cuentas_add_pago` acepta además `p_ref` (no repetir) y `p_fecha` (fecha real del pago), pensados para una cola de reintentos en el iPhone, aparcada de momento.
- Avisos del servidor (título / texto): "−X € · K" / "C · COMERCIO" · "−X € · K" / "COMERCIO · Falta confirmar la cuenta" · "−X € · COMERCIO" / "Pendiente de categorizar". El título nunca es "Cuentas": iOS ya añade debajo "from Cuentas" (en inglés, no se puede quitar) y saldría repetido. Enlaces `#mov=<id>` y `#pend=<id>`. iOS no permite botones ni desplegables en avisos de una web app.
- Regla de Adri: si no llega el aviso de Cuentas, el pago se apunta a mano.

## Si cambia de iPhone, se le rompe o lo pierde

Los datos están en Supabase: no se pierde nada. En el iPhone nuevo:

1. Safari → https://adgara01.github.io/Cuentas/ → Compartir → Añadir a pantalla de inicio. Abrirla desde el icono e iniciar sesión.
2. Ajustes → Bloqueo: volver a poner el PIN y Face ID (se guardan solo en cada dispositivo).
3. Ajustes → Mi cuenta → Notificaciones: activar y pulsar la prueba (cada iPhone tiene su propia suscripción).
4. Atajo de Apple Pay: crear de nuevo la automatización de Cartera (las automatizaciones no se sincronizan por iCloud; los atajos normales sí). Pasos en "Atajo de Apple Pay". La URL y la apikey se copian desde Ajustes → Pagos con Apple Pay; la clave `ck_…` desde Ajustes → Mi cuenta → Clave del Atajo.

Si lo ha **perdido o se lo han robado**, además:
- Ajustes → Mi cuenta → Clave del Atajo → **Generar una clave nueva**, para que la del móvil perdido deje de valer, y ponerla en el atajo del nuevo.
- Cambiar la contraseña de Cuentas (Ajustes → Mi cuenta → Cambiar contraseña).
- Opcional, quitar las suscripciones de avisos viejas: `select user_id, endpoint from cuentas_push_subs;` y borrar las que no sean del móvil nuevo.

Mejora prevista para cuando haga falta: pasar la acción a un atajo normal ("Enviar pago a Cuentas", viaja por iCloud) y dejar la automatización solo con "Ejecutar atajo". Para compartirlo con otra persona, usar "Configuración de importación" para que pida su propia clave `ck_…` (con la de Adri, los pagos entrarían en su cuenta).

## Pendiente

- Confirmar el aviso de Cuentas con un pago real.
- Añadir a `supabase/` los SQL que faltan (`cuentas-push.sql` con `<SECRETO>`, `cuentas-usuario.sql`) y el código de la Edge Function.
- Borrar la rama `claude-prueba-permisos`, los movimientos de prueba de 1 €, y el archivo local `claves_notificaciones_NO_SUBIR.txt`.
- Probar Face ID; registrar la nómina de julio; enlazar tarjetas en Ajustes → Pagos con Apple Pay.
- Aplicar las skills `pwa-diseno-estilo-adri`, `pwa-pin-faceid-rapido` y `pwa-fluidez-animaciones` a NutriFit (repo `adgara01/NutriFit`).
