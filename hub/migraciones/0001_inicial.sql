-- device-track — esquema inicial.
--
-- Todo vive en el esquema `dt` para que el hub pueda compartir base de datos
-- con otra aplicación sin pisarle las tablas. Quien clone el repo levanta este
-- archivo en un Postgres vacío y ya.
--
-- El aislamiento entre organizaciones lo aplica el código (toda consulta del
-- panel filtra por `org`, y la de un equipo por SU equipo). No hay RLS a
-- propósito: el hub conecta con un solo rol y una política por fila obligaría
-- a fijar un GUC por petición sin ganar nada que el filtro explícito no dé ya.

create schema if not exists dt;

-- Una organización es el inquilino. En una instalación de un solo dueño
-- habrá exactamente una y nadie la nota. Aquí vive también la configuración
-- que se les manda a los equipos.
create table if not exists dt.org (
  id               bigserial primary key,
  nombre           text        not null,
  slug             text        not null unique,
  -- Cada cuánto reporta un equipo. 10 min es lo que Android deja con el
  -- teléfono dormido (Doze: una alarma por app cada ~9 min).
  intervalo_s      integer     not null default 600 check (intervalo_s between 60 and 86400),
  -- Si se les pide la ubicación a los equipos. Apagada, el equipo no la manda
  -- y el hub tampoco la guardaría.
  ubicacion        boolean     not null default true,
  -- Días que se guarda el historial de reportes. Lo viejo se borra solo.
  dias_historial   integer     not null default 90 check (dias_historial between 1 and 3650),
  -- Adónde se avisa cuando se abre o se cierra una alerta. El POST va firmado
  -- con `webhook_secreto` (HMAC-SHA256) para que quien lo recibe sepa que es
  -- de aquí.
  webhook_url      text        not null default '',
  webhook_secreto  text        not null default '',
  creado           timestamptz not null default now()
);

-- Una persona del panel. Entra por invitación: el administrador la da de alta
-- con su correo y le pasa un enlace de un solo uso donde ella pone su clave.
--
-- `admin` todo; `editor` equipos, órdenes, zonas, reglas y códigos de alta;
-- `consulta` solo mira.
create table if not exists dt.usuario (
  id                 bigserial primary key,
  org                bigint      not null references dt.org(id) on delete cascade,
  correo             text        not null unique,
  clave_hash         text,
  nombre             text        not null default '',
  rol                text        not null default 'editor'
                       check (rol in ('admin', 'editor', 'consulta')),
  invitacion_hash    text,
  invitacion_vence   timestamptz,
  creado             timestamptz not null default now(),
  ultimo_acceso      timestamptz
);
create index if not exists usuario_invitacion_idx
  on dt.usuario (invitacion_hash) where invitacion_hash is not null;

-- Llave de API para scripts y otros sistemas (`dtk_<prefijo>_<secreto>`). Se
-- guarda el hash; el secreto se enseña una sola vez al crearla.
create table if not exists dt.llave (
  id          bigserial primary key,
  org         bigint      not null references dt.org(id) on delete cascade,
  nombre      text        not null,
  prefijo     text        not null,
  clave_hash  text        not null,
  permisos    text[]      not null default '{leer}',
  creado      timestamptz not null default now(),
  ultimo_uso  timestamptz,
  revocada    timestamptz
);
create index if not exists llave_prefijo_idx on dt.llave (prefijo);

-- Código de alta (`dta_<prefijo>_<secreto>`). Lo único que permite es dar de
-- alta equipos en su organización. Va en un QR o compilado dentro de una app,
-- y una app es pública: por eso lleva tope de usos y vencimiento, y se puede
-- anular sin tocar a los equipos que ya entraron con él.
create table if not exists dt.alta (
  id          bigserial primary key,
  org         bigint      not null references dt.org(id) on delete cascade,
  nombre      text        not null,
  prefijo     text        not null,
  clave_hash  text        not null,
  -- Los equipos NUEVOS que entren con este código caen en este grupo.
  grupo       text        not null default '',
  usos_max    integer     check (usos_max is null or usos_max > 0),
  usos        integer     not null default 0,
  vence       timestamptz,
  creado      timestamptz not null default now(),
  creado_por  text        not null default '',
  anulada     timestamptz
);
create index if not exists alta_prefijo_idx on dt.alta (prefijo);

-- Un equipo. Lo que dice de sí mismo (modelo, huella, último estado) lo
-- escribe el equipo; lo que dice el inventario (nombre, etiqueta, grupo, a
-- quién está asignado, estado) lo escribe una persona.
--
-- `huella` es el ANDROID_ID: sobrevive a desinstalar y reinstalar, y es la
-- misma para todas las apps firmadas con la misma llave (el agente y las apps
-- propias). Es lo que junta en UN equipo al agente y a una app que corren en
-- el mismo teléfono.
create table if not exists dt.equipo (
  id                    bigserial primary key,
  org                   bigint      not null references dt.org(id) on delete cascade,
  nombre                text        not null default '',
  etiqueta              text        not null default '',
  serie                 text        not null default '',
  huella                text,
  modelo                text        not null default '',
  fabricante            text        not null default '',
  android               integer,
  grupo                 text        not null default '',
  asignado_a            text        not null default '',
  notas                 text        not null default '',
  estado                text        not null default 'activo'
                          check (estado in ('activo', 'guardado', 'perdido', 'retirado')),
  alta                  bigint      references dt.alta(id) on delete set null,
  -- Presencia: `conectado` mientras haya un WebSocket abierto; `ultima_vez`,
  -- el último contacto de cualquier tipo (reporte, socket).
  conectado             boolean     not null default false,
  primera_vez           timestamptz not null default now(),
  ultima_vez            timestamptz not null default now(),
  -- El último estado conocido, para pintar el inventario sin ir al historial.
  ultimo_reporte        timestamptz,
  ultimo_motivo         text,
  bateria               integer,
  cargando              boolean,
  red_tipo              text,
  red_ssid              text,
  lat                   double precision,
  lng                   double precision,
  precision_m           real,
  ubicacion_t           timestamptz,
  almacenamiento_libre  bigint,
  almacenamiento_total  bigint,
  -- La lista de apps instaladas, tal como la mandó el equipo la última vez.
  apps                  jsonb       not null default '[]'::jsonb,
  apps_t                timestamptz
);
create unique index if not exists equipo_huella_idx on dt.equipo (org, huella) where huella is not null;
create index if not exists equipo_serie_idx on dt.equipo (org, serie) where serie <> '';
create index if not exists equipo_org_idx on dt.equipo (org, ultima_vez desc);

-- Quién reporta por un equipo: el agente, o cada app con el plugin. Cada
-- fuente tiene su propia credencial (`dtd_<prefijo>_<secreto>`): revocar la de
-- una app no deja ciego al agente. `contexto` es lo que la app cuenta (empresa,
-- quién tiene la sesión, almacén): la app decide, el hub lo guarda y lo enseña.
create table if not exists dt.fuente (
  id          bigserial primary key,
  equipo      bigint      not null references dt.equipo(id) on delete cascade,
  tipo        text        not null check (tipo in ('agente', 'app')),
  paquete     text        not null,
  version     text        not null default '',
  build       integer,
  contexto    jsonb       not null default '{}'::jsonb,
  prefijo     text        not null,
  clave_hash  text        not null,
  creado      timestamptz not null default now(),
  ultima_vez  timestamptz not null default now(),
  revocada    timestamptz,
  unique (equipo, paquete)
);
create index if not exists fuente_prefijo_idx on dt.fuente (prefijo);

-- El historial. Una fila por reporte, con la hora en que pasó (`t`), no con
-- la hora en que llegó (`recibido`): un equipo sin red guarda y manda después.
create table if not exists dt.reporte (
  id                    bigserial primary key,
  equipo                bigint      not null references dt.equipo(id) on delete cascade,
  fuente                bigint      references dt.fuente(id) on delete set null,
  t                     timestamptz not null,
  recibido              timestamptz not null default now(),
  motivo                text        not null default 'periodico',
  bateria               integer,
  cargando              boolean,
  red_tipo              text,
  red_ssid              text,
  lat                   double precision,
  lng                   double precision,
  precision_m           real,
  almacenamiento_libre  bigint
);
create index if not exists reporte_equipo_t_idx on dt.reporte (equipo, t desc);
create index if not exists reporte_t_idx on dt.reporte (t);

-- Una zona: el almacén, la sucursal. Un círculo, que es lo que se dibuja con
-- un dedo en el mapa y lo que se calcula sin librerías.
create table if not exists dt.zona (
  id       bigserial primary key,
  org      bigint           not null references dt.org(id) on delete cascade,
  nombre   text             not null,
  lat      double precision not null check (lat between -90 and 90),
  lng      double precision not null check (lng between -180 and 180),
  radio_m  integer          not null check (radio_m between 10 and 100000),
  creado   timestamptz      not null default now()
);

-- Qué vigilar. `grupo` vacío = todos los equipos de la organización.
--
--   sin_reporte    {minutos}     pasa ese tiempo sin contacto
--   bateria_baja   {porcentaje}  reporta por debajo y no está cargando
--   fuera_de_zona  {zona}        su ubicación queda fuera del círculo
--   apagado        {}            avisa que se apaga
create table if not exists dt.regla (
  id          bigserial primary key,
  org         bigint      not null references dt.org(id) on delete cascade,
  nombre      text        not null default '',
  tipo        text        not null
                check (tipo in ('sin_reporte', 'bateria_baja', 'fuera_de_zona', 'apagado')),
  grupo       text        not null default '',
  parametros  jsonb       not null default '{}'::jsonb,
  activa      boolean     not null default true,
  creado      timestamptz not null default now()
);
create index if not exists regla_org_idx on dt.regla (org) where activa;

-- Una alerta abierta (o ya cerrada) de una regla sobre un equipo. Solo puede
-- haber una abierta por regla y equipo: lo que se repite no abre otra.
create table if not exists dt.alerta (
  id        bigserial primary key,
  org       bigint      not null references dt.org(id) on delete cascade,
  equipo    bigint      not null references dt.equipo(id) on delete cascade,
  regla     bigint      not null references dt.regla(id) on delete cascade,
  tipo      text        not null,
  abierta   timestamptz not null default now(),
  cerrada   timestamptz,
  detalle   jsonb       not null default '{}'::jsonb,
  nota      text        not null default ''
);
create unique index if not exists alerta_abierta_idx
  on dt.alerta (regla, equipo) where cerrada is null;
create index if not exists alerta_org_idx on dt.alerta (org, abierta desc);

-- Una orden para un equipo. Llega al instante por el WebSocket si está
-- conectado y, si no, en la respuesta de su siguiente reporte. Vence: un
-- «suena» que llega ocho horas tarde ya no sirve y molesta.
create table if not exists dt.orden (
  id          bigserial primary key,
  org         bigint      not null references dt.org(id) on delete cascade,
  equipo      bigint      not null references dt.equipo(id) on delete cascade,
  tipo        text        not null check (tipo in ('sonar', 'mensaje', 'reportar')),
  datos       jsonb       not null default '{}'::jsonb,
  estado      text        not null default 'pendiente'
                check (estado in ('pendiente', 'enviada', 'recibida', 'hecha', 'fallida', 'vencida')),
  detalle     text        not null default '',
  creado      timestamptz not null default now(),
  creado_por  text        not null default '',
  enviada     timestamptz,
  actualizada timestamptz not null default now(),
  vence       timestamptz not null default now() + interval '1 hour'
);
create index if not exists orden_viva_idx on dt.orden (equipo) where estado in ('pendiente', 'enviada');
create index if not exists orden_equipo_idx on dt.orden (equipo, creado desc);
