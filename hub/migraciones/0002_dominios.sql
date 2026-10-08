-- Dominios: agrupan equipos dentro de una organización, y acotan a quién los ve.
--
-- Un dominio es «de quién o dónde es este equipo»: una empresa a la que se le
-- da servicio, un almacén, una sucursal. Cada equipo está en uno. A una persona
-- del panel o a una llave de API se le puede limitar a uno o varios dominios:
-- entonces solo ve y maneja esos equipos, con sus zonas, reglas, alertas y
-- códigos de alta. El encargado de un cliente ve lo suyo; el administrador,
-- todo.
--
-- Reemplaza al `grupo` de texto libre, que solo servía para filtrar: no se le
-- podía colgar un permiso a una palabra que cualquiera escribía distinta.
--
-- Toda organización tiene el dominio «General». Quien no necesite la
-- separación se queda con ese y no se entera de que existe.

create table if not exists dt.dominio (
  id          bigserial primary key,
  org         bigint      not null references dt.org(id) on delete cascade,
  nombre      text        not null,
  slug        text        not null,
  descripcion text        not null default '',
  creado      timestamptz not null default now(),
  unique (org, slug)
);

insert into dt.dominio (org, nombre, slug)
select id, 'General', 'general' from dt.org
on conflict (org, slug) do nothing;

-- Cada grupo que ya existía pasa a ser un dominio con su mismo nombre. Dos
-- grupos que solo se distinguían por acentos o signos («Almacén A» y
-- «almacen-a») quedan en uno: era casi seguro el mismo escrito dos veces. El
-- grupo de un código anulado no crea dominio: ese código cae en General.
create or replace function pg_temp.slug(t text) returns text language sql immutable as $$
  select coalesce(nullif(trim(both '-' from regexp_replace(
    translate(lower(t), 'áàäâéèëêíìïîóòöôúùüûñç', 'aaaaeeeeiiiioooouuuunc'),
    '[^a-z0-9]+', '-', 'g')), ''), 'dominio')
$$;

insert into dt.dominio (org, nombre, slug)
select distinct on (org, pg_temp.slug(grupo)) org, grupo, pg_temp.slug(grupo)
  from (select org, grupo from dt.equipo where grupo <> ''
        union select org, grupo from dt.alta where grupo <> '' and anulada is null
        union select org, grupo from dt.regla where grupo <> '') g
 order by org, pg_temp.slug(grupo), grupo
on conflict (org, slug) do nothing;

-- El equipo: no se borra un dominio con equipos dentro (el API lo dice antes
-- con un 409; la llave foránea es la red).
alter table dt.equipo add column if not exists dominio bigint references dt.dominio(id);
update dt.equipo e
   set dominio = d.id
  from dt.dominio d
 where d.org = e.org
   and d.slug = case when e.grupo = '' then 'general' else pg_temp.slug(e.grupo) end;
alter table dt.equipo alter column dominio set not null;
alter table dt.equipo drop column grupo;
create index if not exists equipo_dominio_idx on dt.equipo (dominio);

-- El código de alta: los equipos nuevos que entren con él caen en su dominio.
-- Borrar el dominio se lleva sus códigos (para entonces ya no queda ninguno
-- vigente: el API no lo deja borrar antes). La fila del código no se rehace:
-- su hash sigue siendo el mismo, y un código compilado dentro de una app
-- sigue valiendo.
alter table dt.alta add column if not exists dominio bigint references dt.dominio(id) on delete cascade;
update dt.alta a
   set dominio = coalesce(
         (select d.id from dt.dominio d
           where d.org = a.org
             and d.slug = case when a.grupo = '' then 'general' else pg_temp.slug(a.grupo) end),
         (select d.id from dt.dominio d where d.org = a.org and d.slug = 'general'));
alter table dt.alta alter column dominio set not null;
alter table dt.alta drop column grupo;

-- La regla: sin dominio vigila a todos los equipos de la organización; con
-- dominio, solo a los suyos.
alter table dt.regla add column if not exists dominio bigint references dt.dominio(id) on delete cascade;
update dt.regla r
   set dominio = d.id
  from dt.dominio d
 where d.org = r.org and r.grupo <> '' and d.slug = pg_temp.slug(r.grupo);
alter table dt.regla drop column grupo;

-- La zona: sin dominio es de toda la organización y la ven todos; con
-- dominio, solo quien alcanza ese dominio. Las coordenadas de un almacén
-- también son del cliente.
alter table dt.zona add column if not exists dominio bigint references dt.dominio(id) on delete cascade;

-- A quién alcanza una persona o una llave. Vacío = toda la organización.
-- Un arreglo y no una tabla de enlace: se lee en cada petición junto con el
-- rol, y el API no deja borrar un dominio que todavía figure aquí.
alter table dt.usuario add column if not exists dominios bigint[] not null default '{}';
alter table dt.llave add column if not exists dominios bigint[] not null default '{}';

-- Administrar es de toda la organización. El API ya lo rechaza; esto es la red.
alter table dt.usuario add constraint usuario_admin_sin_dominios
  check (rol <> 'admin' or dominios = '{}');
alter table dt.llave add constraint llave_admin_sin_dominios
  check (not ('admin' = any(permisos)) or dominios = '{}');
