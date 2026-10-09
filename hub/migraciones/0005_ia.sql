-- El asistente de IA de cada organización.
--
-- Cada organización pone SUS credenciales del proveedor (Organización →
-- Asistente IA): el hub no trae una clave propia ni presta la de otra
-- organización. Sin ellas, esa organización no tiene asistente y el panel
-- funciona igual que siempre.
--
-- {proveedor: anthropic|gemini, modelo, clave, activo}. La clave va en claro
-- porque hace falta para llamar al proveedor, igual que la del correo de
-- salida; la API nunca la devuelve (solo `clave_puesta`). Ver SECURITY.md.

alter table dt.org add column if not exists ia jsonb not null default '{}'::jsonb;

-- Lo que gasta cada llamada al proveedor, en tokens. El proveedor cobra a la
-- organización (es su clave); esto es para que ella vea en qué se le va.
create table if not exists dt.ia_uso (
  id               bigserial primary key,
  org              bigint      not null references dt.org(id) on delete cascade,
  usuario          bigint      references dt.usuario(id) on delete set null,
  llave            bigint      references dt.llave(id) on delete set null,
  -- `prueba` (el botón de Organización), `chat`, `tablero`.
  origen           text        not null,
  proveedor        text        not null,
  modelo           text        not null,
  entrada          integer     not null default 0,
  salida           integer     not null default 0,
  cache_lectura    integer     not null default 0,
  cache_escritura  integer     not null default 0,
  t                timestamptz not null default now()
);
create index if not exists ia_uso_org_idx on dt.ia_uso (org, t desc);
