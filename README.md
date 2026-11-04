# PULSO

Tus agentes, de un vistazo. App nativa SwiftUI para iPhone: Codex, GitHub Copilot y Claude en un panel negro y minimalista, vertical u horizontal.

## Abrir y ejecutar

1. Abre `Pulso.xcodeproj` en Xcode 15 o posterior (verificado con el Xcode instalado y simulador iOS 27.2).
2. Selecciona el esquema **Pulso** y un simulador de iPhone. Ejecuta con ⌘R.
3. En **Conexiones**, activa **Mostrar datos de ejemplo** para explorar la interfaz sin credenciales. También admite el argumento `--demo`.
4. Para instalar en tu iPhone, elige tu equipo en **Signing & Capabilities** de Pulso y PulsoWidgets. Debes registrar identificadores y App Group con tu equipo. El grupo `group.com.jesusom.pulso` debe coincidir en los dos entitlements y en `Core/UsageModels.swift`. Si cambias el bundle ID, cambia también el servicio del llavero en `Core/TokenVault.swift`. Un equipo sin capacidad App Groups no permite los widgets compartidos.

Sin paquetes de terceros, backend, Mac puente o claves de API de OpenAI.

## Conectar Copilot

Esta primera versión usa un **token personal**, no OAuth. Es una decisión de entrega: un login OAuth pulido requiere registrar una aplicación propia de GitHub; no se incluyen identificadores ajenos ni secretos de cliente.

- Cuenta personal de Copilot facturada a tu usuario de GitHub.
- Token personal con permiso **Plan → Read**. El enlace de creación está en Conexiones.
- Introduce tu usuario, token y, opcionalmente, los créditos incluidos en tu cuota mensual. Ese límite se etiqueta **manual**. Sin él solo se muestra consumo, no se inventa un porcentaje restante.
- Si tu plan conserva peticiones premium, activa la opción correspondiente e introduce un límite en peticiones, no en créditos.
- Se consulta el uso **bruto** mensual de Copilot; no es una predicción de factura ni representa límites horarios/semanales adicionales. Los informes pueden llevar retraso.
- Las licencias facturadas a una empresa/organización requieren una integración distinta y no quedan cubiertas por el endpoint personal.

El token se guarda en el llavero con `WhenUnlockedThisDeviceOnly`. No se comparte con widgets. Desconectar borra el token y la lectura compartida.

Fuente oficial: https://docs.github.com/en/rest/billing/usage

## Conectar Codex (experimental)

1. Abre **Conexiones → Abrir sesión de ChatGPT**.
2. Inicia sesión en la página oficial dentro del navegador de la app.
3. Pulsa **Consultar cuota**.

La app intenta leer `/backend-api/wham/usage` desde `chatgpt.com`, utilizando la sesión web de ese sitio. **Es una integración privada, sin garantía de compatibilidad.** La sesión se mantiene únicamente en el almacenamiento WebKit local; el token de sesión no se devuelve a Swift ni se guarda en el caché de los widgets. Se aceptan solo ventanas de uso conocidas y validadas; un formato diferente muestra un error.

Google/Apple/SSO, CAPTCHA u otras políticas pueden impedir iniciar sesión en un navegador integrado. Si ocurre, esta versión no puede conectar esa cuenta; no incluye un bypass ni presume que la sesión está autenticada. Los widgets y el panel permanecen con datos desconocidos o con la última lectura identificada como desactualizada.

La consulta oficial documentada de límites de Codex utiliza app-server; esto explica por qué el adaptador web de una app exclusivamente iPhone es experimental: https://learn.chatgpt.com/docs/app-server

## Conectar Claude (experimental)

1. Abre **Conexiones → Abrir sesión de Claude**.
2. Inicia sesión en `claude.ai` y pulsa **Consultar cuota**.
3. Si tienes varios espacios de trabajo, selecciona uno en **Conexiones → Espacio de trabajo**. PULSO no elige uno arbitrariamente.

Se muestran las ventanas de sesión y semanales devueltas por Claude, con límites adicionales por modelo cuando estén disponibles. Son cuotas de tu plan compartidas con Claude Code, no gasto de la API ni actividad individual de agentes.

La integración intenta consultar `/api/organizations` y `/api/organizations/{id}/usage` desde el propio sitio de Claude. **Son endpoints privados y experimentales**: pueden cambiar, bloquear el navegador integrado o rechazar la sesión. No se ha validado un inicio de sesión con tu cuenta real. No se utiliza una clave de API de Anthropic.

La sesión web se guarda en un contenedor WebKit exclusivo; borrar Claude conserva la sesión de Codex y viceversa. Los widgets reciben únicamente lecturas de cuota. **Borrar sesión web de Claude** está disponible incluso si cierras el navegador antes de consultar. Una renovación desconocida se deja sin fecha; no se inventa un reinicio.

Fuentes oficiales sobre las cuotas y la diferencia con analítica de organizaciones: https://support.claude.com/en/articles/11647753-how-do-usage-and-length-limits-work y https://platform.claude.com/docs/en/manage-claude/usage-cost-analytics-api

## Escritorio, Always-On y StandBy

- En vertical: proveedores apilados. En horizontal: lado a lado.
- El botón de pantalla activa **modo escritorio**: oculta parte del sistema y desactiva el temporizador de bloqueo **solo mientras la app esté activa**. Se restaura al salir o desactivar el modo.
- El tono nocturno atenúa el aspecto hacia rojo; no controla el brillo físico ni las opciones del sistema.
- Para **StandBy** de iOS: carga el iPhone, déjalo de lado y añade los widgets **Codex**, **Copilot** y **Claude** de PULSO.
- Los widgets leen la última consulta guardada por la app. No consultan cuentas en segundo plano. Muestran el momento de lectura y se marcan sin actualizar tras cinco minutos; iOS decide cuándo renderiza cada entrada y permite actualizar cada widget.
- **Always-On real** depende del hardware, la configuración y las decisiones de iOS. La app no puede forzarlo con el iPhone bloqueado.
- PULSO consulta cada minuto mientras está abierta; las fuentes pueden publicar datos con retraso. No muestra agentes trabajando ni actividad por sesión porque los informes de cuota no permiten comprobarlo.

Apple: https://developer.apple.com/documentation/uikit/uiapplication/isidletimerdisabled

## Proyecto y comprobaciones

- `App/`: panel, ajustes, estado y navegador experimental.
- `Core/`: modelos, parsers, cliente GitHub y llavero.
- `Widgets/`: tres widgets sin credenciales.
- `Tests/`: parsers, fronteras de cuota y transporte GitHub simulado.
- `UITests/`: demostración, salida, modo escritorio, rotación, ajustes y texto grande.

Regenerar referencias tras añadir archivos (no instala herramientas):

```sh
python3 scripts/generate_project.py
```

Compilar o ejecutar pruebas; sustituye el destino por un iPhone instalado:

```sh
xcodebuild -project Pulso.xcodeproj -scheme Pulso \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO test
```

Las capturas se adjuntan a los resultados de XCTest. Las pruebas usan datos sintéticos; no prueban tus sesiones reales. Las comprobaciones de OAuth/SSO, cuota de tu cuenta, Always-On físico y StandBy deben hacerse en el iPhone con tus credenciales. No se ha publicado ni firmado para distribución.

## Capturas y validación

[Vertical](docs/screenshots/portrait.png) · [Horizontal](docs/screenshots/landscape.png) · [Claude](docs/screenshots/claude.png) · [Texto grande](docs/screenshots/large-text.png). Todas muestran datos de ejemplo.

Verificado: compilación de app y extensión, 24 pruebas unitarias y 4 flujos de interfaz sin fallos tras añadir Claude. Revisión independiente sin problemas importantes pendientes. Los resultados locales están bajo `build/*.xcresult` y quedan fuera del control de versiones.
