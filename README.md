<p align="center">
  <img src="docs/images/icon.png" width="112" height="112" alt="Icono de Cue">
</p>

<h1 align="center">Cue</h1>

<p align="center">
  Tu guion, justo debajo de la cámara.<br>
  Teleprompter para <b>Mac</b>, <b>iPhone</b> y <b>iPad</b>: vive en el notch, arranca solo cuando grabas y nadie lo ve cuando compartes pantalla.
</p>

<p align="center">
  <a href="https://manuekle.github.io/cue/"><b>Web</b></a> ·
  <a href="https://github.com/Manuekle/cue/releases/latest"><b>Descargar para Mac</b></a> ·
  <a href="#compilar"><b>Compilar</b></a>
</p>

<p align="center">
  <img src="docs/images/hero.webp" alt="Cue abierto bajo el notch de un MacBook durante una llamada de Google Meet">
</p>

> Antes se llamaba **Pronter**. El nombre cambió a Cue; tus guiones, ajustes y permisos se conservan.

## Mac

<img src="docs/images/auto-start.webp" alt="Cue contando 3, 2, 1 bajo el notch al encenderse la cámara">

- **Arranca solo.** Cuando cualquier app enciende la cámara (Zoom, Meet, Teams, FaceTime, QuickTime, OBS…), Cue abre el guion bajo el notch, cuenta 3, 2, 1 y empieza a avanzar. Al apagar la cámara, se pausa. También puede usar el micrófono como señal.
- **Vive en el notch.** Una pestaña negra sale del notch con el estado y el tiempo. Clic en el notch para abrir el prompter y otro clic (o Esc) para guardarlo. En Macs sin notch queda pegada bajo la barra de menús.
- **Invisible al compartir.** La ventana se excluye de la captura de pantalla: no aparece en Meet, Zoom ni en grabaciones. Solo la ves tú.
- **Siempre encima**, también sobre apps a pantalla completa, y sigue activa en la barra de menús aunque cierres la ventana.

<img src="docs/images/cards.webp" alt="Pestaña del notch, comparación al compartir pantalla, modo Sigue mi voz y atajos de teclado">

### Copiloto

<img src="docs/images/copilot.webp" alt="Panel del Copiloto con una respuesta sugerida y la transcripción de la llamada">

Escucha la llamada y te dice qué responder.

1. En la barra lateral, **Copiloto**: escribe un contexto (quién eres, de qué va la llamada, tus objetivos y datos clave).
2. Pulsa el micrófono. **Whisper** (WhisperKit, en tu Mac) transcribe tu micrófono (**Tú**) y el audio del sistema (**Ellos**).
3. Cuando la otra persona termina de hablar, aparece una respuesta de 1 a 3 frases lista para leer, en el idioma de la conversación. También con ⌃⌥↩.

| Motor | Dónde corre |
|---|---|
| Apple Intelligence (macOS 26+) | En tu Mac |
| Ollama (`localhost:11434`, p. ej. `qwen2.5:7b`) | En tu Mac |
| OpenAI, Gemini, Claude, Muse, Ollama Cloud | En la nube, con tu propia clave (guardada en el Llavero) |

Whisper se descarga la primera vez (Rápido 145 MB, Equilibrado 480 MB, Preciso 630 MB) en `~/Library/Application Support/Pronter/Models`. Pide permiso de **Micrófono** y de **Grabación de pantalla y audio del sistema** (solo se usa el audio). Usa audífonos para que tu micrófono no repita a la otra persona.

### Atajos

Funcionan desde cualquier app, incluso a pantalla completa.

| Atajo | Acción |
|---|---|
| ⌃⌥ Espacio | Reproducir / pausa |
| ⌃⌥ P | Abrir / guardar el prompter |
| ⌃⌥ R | Volver al inicio |
| ⌃⌥ ↑ / ↓ | Más rápido / más lento |
| ⌃⌥ ← / → | Guion anterior / siguiente |
| ⌃⌥ ↩ | Copiloto: ¿qué digo? |
| ⌃⌥ L | Copiloto: escuchar / detener |
| ⌥⌘ 1–9 | Ir al guion 1–9 de la lista |
| ⌃⌥⌘ 1–9 / 0 | Cambiar a la sesión 1–9 / ver todos |

Con el prompter al frente: espacio, ↑/↓, ←/→, 1–9, + / −, R, M (espejo) y Esc. La rueda o el trackpad mueven el texto.

## iPhone y iPad

<p align="center">
  <img src="docs/images/iphone-floating.webp" width="260" alt="Ventana flotante de Cue sobre la app Cámara">
  &nbsp;&nbsp;&nbsp;
  <img src="docs/images/iphone-camera.webp" width="260" alt="Cámara de Cue con el guion junto al lente">
</p>

| Modo | Para qué sirve |
|---|---|
| **Flotante** | El guion en una ventana Picture in Picture encima de **cualquier app**: Cámara, Instagram, TikTok, WhatsApp, Zoom… Al grabar en esa app, Cue lo nota, cuenta y arranca solo. Al parar, se pausa. Horizontal o vertical. |
| **Grabar** | La cámara de Cue con el guion junto al lente. Cuenta regresiva y luego el video y el texto arrancan a la vez. **Sigue mi voz** avanza mientras hablas y espera cuando callas. Estilos de color (Cálido, Cine, B/N…), luz de estudio y fondo desenfocado tipo retrato. El video va a Fotos. |
| **Leer** | Prompter a pantalla completa, sin cámara. |

Mientras lees: toca para pausar, desliza para avanzar o volver, pellizca para cambiar el tamaño, y usa − / + para la velocidad en palabras por minuto.

**Cómo sabe que estás grabando:** iOS no avisa a una app cuando otra graba. Mientras la ventana flotante está abierta, Cue mantiene una sesión de audio; cuando otra app empieza a grabar, iOS la interrumpe, y esa es la señal para contar y arrancar. Si una app no lo hace, toca ▶.

## Sesiones

Agrupa tus guiones por proyecto, canal o cliente. Cada guion pertenece a una sesión; **Todos** muestra todos. Los guiones nuevos se crean en la sesión activa. Eliminar una sesión no borra sus guiones: pasan a **Todos**.

- **iPhone/iPad:** barra de sesiones sobre la lista y menú de carpeta para crear, renombrar o eliminar. Mantén pulsado un guion → *Mover a sesión*.
- **Mac:** selector en la barra lateral y en el menú de la barra de menús. Clic derecho en un guion → *Mover a sesión*.

## Compilar

Requiere Xcode 16 o posterior, macOS 14+ e iOS 17+. El proyecto se genera con [XcodeGen](https://github.com/yonaskolb/XcodeGen) desde `project.yml`:

```bash
xcodegen generate
```

```bash
open Pronter.xcodeproj
```

- **Mac:** esquema `PronterMac` → Run. El resultado es `Cue.app`; cópialo a `/Applications` para dejarlo instalado.
- **iPhone/iPad:** esquema `Pronter`, tu dispositivo como destino → Run.

La prueba de punta a punta en un iPhone real (abre la ventana flotante, graba con la app Cámara y comprueba que el texto arrancó solo):

```bash
xcodebuild test -project Pronter.xcodeproj -scheme Pronter -destination 'id=<UDID del iPhone>' -allowProvisioningUpdates
```

Los textos en español viven en `Shared/Localizable.xcstrings`. Después de añadir textos, compila con `SWIFT_EMIT_LOC_STRINGS=YES` y ejecuta `tools/sync-strings.py`.

## Estructura

| Carpeta | Contenido |
|---|---|
| `Shared/` | Guiones, sesiones, ajustes, motor del prompter (cuenta regresiva, velocidad, posición) y la vista del texto |
| `Shared/Theme.swift` | Estilo visual: vidrio negro, azul `#0A84FF`, fuentes SN Pro, Hanken Grotesk y Geist Mono, íconos Hugeicons |
| `macOS/` | Panel del notch, detección de cámara y micrófono, atajos globales |
| `macOS/Copilot/` | Captura de audio, Whisper (WhisperKit) y los motores de IA |
| `iOS/` | Cámara con filtros, ventana flotante (PiP), detector de grabación y lector |
| `site/` | La web, HTML estático publicado en GitHub Pages |
| `tools/` | Conversión de íconos Hugeicons y sincronización de textos |

## Créditos

Fuentes SN Pro, Hanken Grotesk y Geist Mono (OFL). Íconos de [Hugeicons](https://hugeicons.com) (MIT). Logos de apps en la web desde [svgl](https://svgl.app).
