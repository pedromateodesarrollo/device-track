-- El nombre de la app que reporta, el que se ve en el lanzador del teléfono
-- («WMS Duralon», «device-track»). El `paquete` la identifica; el nombre es lo
-- que el panel le enseña a la gente en la columna «Aplicación».
--
-- Lo manda la fuente en el alta y en cada reporte (`fuente.nombre`); una app
-- que todavía no lo manda conserva el que tenga. Mientras tanto el panel lo
-- busca en la lista de apps instaladas del equipo.

alter table dt.fuente add column if not exists nombre text not null default '';
