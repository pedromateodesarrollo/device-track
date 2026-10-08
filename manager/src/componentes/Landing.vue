<script setup>
const diagrama = `  Equipo (agente o app)            Hub                       Quien administra
  ─────────────────────      ───────────────────      ───────────────────────────
  POST /v1/reporte      ──►  guarda el historial,  ──►  panel: mapa, inventario,
  batería, red, GPS          evalúa las reglas          alertas abiertas
  cada 10 min                       │                   webhook a tu sistema
                                    │
  WebSocket abierto     ◄──  «suena 30 s»          ◄──  POST /v1/equipos/42/ordenes
  = figura conectado         (o en el próximo           (el panel, un script, el ERP)
                              reporte si no hay socket)`
</script>

<template>
  <section class="hero">
    <div class="contenedor">
      <span class="etiqueta">Código abierto · Apache-2.0</span>
      <h1>Dónde está cada equipo, y si sigue vivo.</h1>
      <p class="lema">
        Una página donde ves todos los teléfonos y terminales de tu empresa:
        cuántos tienes, dónde están, si siguen funcionando y quién los usa. Y si
        uno se pierde entre los estantes, lo haces sonar desde aquí.
      </p>
      <div class="acciones">
        <a href="#/panel" class="boton">Entrar al panel</a>
        <a href="#/docs" class="boton suave">Ver el API</a>
        <a href="https://github.com/pedromateodesarrollo/device-track" class="boton suave">Código en GitHub</a>
      </div>
    </div>
  </section>

  <section class="seccion">
    <div class="contenedor">
      <h2>Cómo funciona</h2>
      <div class="pasos" style="margin-top: 22px">
        <div class="paso">
          <h3>Una app en cada equipo</h3>
          <p class="apagado">La instalas y escaneas un código QR que te da esta página. Eso es todo: el equipo aparece en tu lista.</p>
        </div>
        <div class="paso">
          <h3>El equipo cuenta cómo está</h3>
          <p class="apagado">Cada 10 minutos, solo y con la pantalla apagada: batería, red, espacio libre, apps instaladas y —si tú lo pides— dónde está.</p>
        </div>
        <div class="paso">
          <h3>Tú lo ves todo aquí</h3>
          <p class="apagado">La lista, el mapa y un aviso cuando algo va mal: sin batería, una hora callado, fuera del almacén, apagado.</p>
        </div>
      </div>
      <img class="captura" src="/img/equipos.jpg" alt="La lista de equipos: nombre, a quién está asignado, si está conectado, batería y red" />
    </div>
  </section>

  <section class="seccion">
    <div class="contenedor">
      <h2>Qué resuelve</h2>
      <div class="rejilla" style="margin-top: 22px">
        <div class="tarjeta">
          <h3>Un inventario que se llena solo</h3>
          <p>Cada equipo se da de alta escaneando un QR. Modelo, Android, serie y apps instaladas los dice él; tú le pones nombre, etiqueta, grupo y a quién está asignado.</p>
        </div>
        <div class="tarjeta">
          <h3>Dónde está y por dónde anduvo</h3>
          <p>La última posición en el mapa, con el círculo de precisión del GPS, y el recorrido de cualquier día. Sin red, el equipo guarda y manda después con la hora de verdad.</p>
        </div>
        <div class="tarjeta">
          <h3>Si sigue vivo</h3>
          <p>Conectado ahora, cuándo reportó por última vez y por qué, batería, red y espacio libre. Lo que lleva un día callado salta a la vista.</p>
        </div>
        <div class="tarjeta">
          <h3>Alertas que se cierran solas</h3>
          <p>Sin reporte, batería baja, fuera de zona, apagado. Para todos o por grupo. Se abren en el panel y por webhook a tu sistema, y se cierran cuando el equipo se recupera.</p>
        </div>
        <div class="tarjeta">
          <h3>Hacer sonar uno perdido</h3>
          <p>Suena a todo volumen aunque esté en silencio, o muestra un aviso en la pantalla: «Devuelve este equipo a la oficina». Llega al instante si está conectado.</p>
        </div>
        <div class="tarjeta">
          <h3>No es un MDM, y no espía</h3>
          <p>No bloquea ni borra equipos. El agente lleva siempre una notificación que dice de quién es el equipo y que reporta su ubicación.</p>
        </div>
      </div>
    </div>
  </section>

  <section class="seccion">
    <div class="contenedor">
      <h2>Tres maneras de reportar</h2>
      <div class="pasos" style="margin-top: 22px">
        <div class="paso">
          <h3>El agente</h3>
          <p class="apagado">Una app Android aparte para cualquier equipo, tenga o no apps propias. Corre en segundo plano, reporta con el teléfono dormido y atiende las órdenes.</p>
        </div>
        <div class="paso">
          <h3>El plugin Flutter</h3>
          <p class="apagado">Para meterlo en una app que ya existe. Reporta mientras está abierta y cuenta su contexto: empresa, quién tiene la sesión, almacén. Con el agente en el mismo teléfono, es UN equipo con dos fuentes.</p>
        </div>
        <div class="paso">
          <h3>El API REST</h3>
          <pre>curl https://TU-HUB/v1/equipos?alerta=1 \
  -H "authorization: Bearer dtk_..."</pre>
          <p class="apagado">Todo lo que hace el panel. Ver la <a href="#/docs">documentación</a>.</p>
        </div>
      </div>
    </div>
  </section>

  <section class="seccion">
    <div class="contenedor">
      <h2>Por dentro</h2>
      <p class="apagado" style="margin: 8px 0 18px">Para quien lo monta o lo integra con otro sistema.</p>
      <div class="diagrama">{{ diagrama }}</div>
    </div>
  </section>
</template>
