-- El chat del asistente de IA y los tableros de la portada.

-- Una conversación con el asistente. Es de la persona: nadie más la ve.
--
-- `mensajes` va en el formato del proveedor y solo se le añade al final: lo
-- que el modelo pensó entre una herramienta y otra (los bloques de
-- razonamiento de Claude, las firmas de Gemini) se le devuelve intacto en la
-- pregunta siguiente. `vista` es lo que la pantalla enseña (lo que dijo cada
-- quien, qué consultó, qué propuso). `pendientes` son las propuestas que la
-- persona confirmó o descartó desde la última pregunta: se le cuentan al
-- modelo con la siguiente.
create table if not exists dt.ia_conversacion (
  id           bigserial primary key,
  org          bigint      not null references dt.org(id) on delete cascade,
  usuario      bigint      not null references dt.usuario(id) on delete cascade,
  titulo       text        not null default '',
  proveedor    text        not null,
  modelo       text        not null,
  mensajes     jsonb       not null default '[]'::jsonb,
  vista        jsonb       not null default '[]'::jsonb,
  pendientes   jsonb       not null default '[]'::jsonb,
  creado       timestamptz not null default now(),
  actualizado  timestamptz not null default now()
);
create index if not exists ia_conversacion_usuario_idx on dt.ia_conversacion (usuario, actualizado desc);

-- Lo que el asistente propuso cambiar y la persona confirma o descarta. Se
-- ejecuta con la sesión de quien confirma, en el momento de confirmar: si
-- entre tanto le quitaron el permiso, no se hace.
create table if not exists dt.ia_propuesta (
  id            bigserial primary key,
  org           bigint      not null references dt.org(id) on delete cascade,
  usuario       bigint      not null references dt.usuario(id) on delete cascade,
  conversacion  bigint      not null references dt.ia_conversacion(id) on delete cascade,
  herramienta   text        not null,
  args          jsonb       not null default '{}'::jsonb,
  resumen       text        not null default '',
  estado        text        not null default 'pendiente'
                  check (estado in ('pendiente', 'hecha', 'fallida', 'descartada')),
  resultado     jsonb,
  creado        timestamptz not null default now(),
  resuelta      timestamptz,
  vence         timestamptz not null default now() + interval '24 hours'
);
create index if not exists ia_propuesta_conversacion_idx on dt.ia_propuesta (conversacion);

-- Un tablero: paneles que consultan las rutas del panel (solo lectura) y
-- dicen cómo dibujarse. Es de quien lo hizo; `compartido` lo enseña a toda la
-- organización, a cada quien con SUS datos (los paneles se calculan con la
-- sesión de quien mira). Quien no tiene uno propio ve el Resumen de siempre.
create table if not exists dt.tablero (
  id           bigserial primary key,
  org          bigint      not null references dt.org(id) on delete cascade,
  usuario      bigint      not null references dt.usuario(id) on delete cascade,
  nombre       text        not null,
  compartido   boolean     not null default false,
  orden        integer     not null default 0,
  paneles      jsonb       not null default '[]'::jsonb,
  creado       timestamptz not null default now(),
  actualizado  timestamptz not null default now()
);
create index if not exists tablero_org_idx on dt.tablero (org, usuario, orden);
