-- El correo de salida de cada organización: con él salen las invitaciones al
-- panel. device-track es independiente: no usa el correo de ningún otro
-- sistema, cada organización pone el suyo desde el panel (Organización →
-- Correo de salida). Sin él, invitar sigue siendo un enlace que se comparte a
-- mano.
--
-- {host, puerto, seguridad: tls|starttls|ninguna, remitente, usuario, clave,
--  nombre}. La clave va en claro porque hace falta para autenticar ante el
-- servidor de correo, como el secreto del webhook; la API nunca la devuelve
-- (solo `clave_puesta`). Ver SECURITY.md.

alter table dt.org add column if not exists correo jsonb not null default '{}'::jsonb;
