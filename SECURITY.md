# Seguridad

## Reportar un fallo

Escribe a **pedromateo.desarrollo@gmail.com** con «device-track» en el asunto.
Si el fallo permite ver equipos o ubicaciones de otra organización (o de un
dominio que no alcanzas), o mandarle órdenes a un equipo ajeno, dilo en la
primera línea.

No abras un issue público para eso. Para todo lo demás, los issues son el sitio.

## Las credenciales y lo que abre cada una

| Prefijo | Qué es | Qué abre |
|---|---|---|
| `dta_` | Código de alta | Dar de alta equipos en UNA organización. Nada más |
| `dtd_` | Credencial de un equipo | Reportar y contestar las órdenes de ESE equipo |
| `dtk_` | Llave de API | Lo que digan sus permisos: `leer`, `editar`, `ordenar`, `admin` |
| JWT | Sesión del panel | Según el rol: `admin`, `editor`, `consulta` |

Una persona o una llave pueden quedar limitadas a unos **dominios** de la
organización: entonces un equipo de otro dominio, con su historial, sus
alertas y sus zonas, es para ellas un 404. El filtro va en cada consulta del
panel y el alcance se lee de la base en cada petición, nunca del cuerpo ni del
JWT. Administrar (personas, llaves, dominios) es de toda la organización: una
sesión limitada nunca es `admin`, y la base lo impide también con una
restricción.

**Un código de alta se trata como semipúblico.** Va en un QR pegado en la
pared o compilado dentro de una app, y una app se puede abrir. Por eso no lee
nada ni manda nada: lo peor que hace alguien con un código robado es dar de
alta equipos falsos, que aparecen en el panel como cualquier otro y se borran.
Ponle tope de usos y vencimiento, y anúlalo cuando ya no haga falta: los
equipos que entraron con él siguen.

Cada fuente de un equipo (el agente, cada app) tiene su propia credencial.
Darse de alta otra vez desde la misma fuente la reemplaza y la anterior deja
de valer.

## Lo que el hub guarda de un equipo

Lo que el equipo manda: modelo, ANDROID_ID, batería, red y nombre de la red
Wi-Fi, espacio libre, la lista de apps instaladas, la ubicación si la
organización la pide, y el `contexto` que ponga cada app (quién tiene la
sesión, en qué almacén). Lo ven las personas y llaves de esa organización que
alcanzan su dominio, nadie más.

El `contexto` lo decide la app: no le pongas nada que no quieras que vea quien
administra el hub.

## Cómo se guardan las credenciales

| Qué | Cómo |
|---|---|
| Claves de usuario | PBKDF2-HMAC-SHA256, 210 000 iteraciones, sal por clave |
| Llaves, códigos de alta y credenciales de equipo | Solo el sha256 del secreto. El secreto se enseña una vez |
| Enlaces de invitación | Solo el sha256; un uso, siete días |
| Sesiones del panel | JWT HS256 con `DT_SECRETO_JWT`, siete días. El rol se lee de la base en cada petición |
| Secreto del webhook | En claro (hace falta para firmar). Se enseña una vez |
| Clave del correo de salida | En claro (hace falta para autenticar ante el servidor SMTP). La API nunca la devuelve: el panel solo sabe si está puesta. Use una cuenta o una clave de aplicación solo para esto |
| Clave del asistente de IA | En claro (hace falta para llamar al proveedor). Es de cada organización, con su propia cuenta; la API nunca la devuelve y viaja solo en la cabecera de la llamada al proveedor, nunca en la URL ni en un log |

Las comparaciones van en tiempo constante. El log nunca lleva una llave ni un
token. Los errores internos devuelven una referencia, no el texto de la
excepción (que trae nombres de tablas). La credencial del WebSocket va en la
cabecera, no en la URL: una URL termina en el log de cualquier proxy.

## Frenos

* Login, registro e invitaciones: 10 intentos por minuto por IP (y por correo
  en el login).
* Alta: 30 por minuto por IP en el hub; `hub/nginx-hub.conf` pone además 10/s
  con ráfaga de 60 delante.
* WebSocket: 8 conexiones por equipo.
* Cuerpos: 2 MB. Un lote de reportes atrasados, 500 como mucho; la lista de
  apps, 1000; el `contexto`, 4 KB.

## Lo que todavía no hace

* No tiene doble factor.
* El webhook no reintenta.
