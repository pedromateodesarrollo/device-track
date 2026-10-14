-- Por qué un equipo tiene (o no tiene) ubicación: sin permiso, con el permiso
-- negado para siempre, con la ubicación del teléfono apagada, sin señal bajo
-- techo, con una posición simulada… Lo manda cada fuente en su reporte
-- (`ubicacion_estado`, ver docs/api.md) y el panel lo enseña en «Ubicación»,
-- con un «Qué hacer» cuando la persona lo puede arreglar.
--
-- Va por FUENTE: el agente puede tener «todo el tiempo» y la app del mismo
-- teléfono no tener permiso. `ubicacion_estado` null = esa fuente es de una
-- versión que todavía no lo manda. `ubicacion_estado_t` es la hora del
-- reporte que lo trajo (un reporte atrasado no pisa a uno más nuevo).
--
-- En el historial va solo el motivo, para ver cuándo dejó de llegar.

alter table dt.fuente add column if not exists ubicacion_estado jsonb;
alter table dt.fuente add column if not exists ubicacion_estado_t timestamptz;
alter table dt.reporte add column if not exists ubicacion_motivo text;
