-- Avisos por correo: cada regla dice a quién avisar cuando abre una alerta.
--
-- El correo sale por el correo de salida de la organización (migración 0003),
-- el mismo de las invitaciones. Sin él, las alertas se ven en el panel y van
-- al webhook como siempre, y la lista no hace nada.

alter table dt.regla add column if not exists avisar text[] not null default '{}';

-- Cuándo salió el correo de una alerta. Una batería que sube y baja junto al
-- umbral abre y cierra la misma alerta cada diez minutos: con esto, la misma
-- regla no vuelve a escribir por el mismo equipo antes de una hora.
alter table dt.alerta add column if not exists avisada_correo timestamptz;
create index if not exists alerta_avisada_idx
  on dt.alerta (regla, equipo, avisada_correo desc) where avisada_correo is not null;
