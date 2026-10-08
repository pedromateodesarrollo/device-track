# Cambios

## 0.1.0 — sin publicar

Primera versión del hub.

* Alta de equipos con código de alta (`dta_`), una credencial por fuente
  (`dtd_`), el agente y una app en el mismo teléfono son un solo equipo.
* Reporte con batería, red, ubicación, almacenamiento, apps y contexto; reportes
  atrasados en lote.
* Órdenes `sonar`, `mensaje` y `reportar`, por WebSocket o en la respuesta del
  reporte; vencen.
* Zonas, reglas (`sin_reporte`, `bateria_baja`, `fuera_de_zona`, `apagado`),
  alertas y webhook firmado.
* Panel, personas con roles (`admin`, `editor`, `consulta`) y llaves de API.
