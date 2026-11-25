# WinForge Engine (`olshhhh/Optimizador`)

> ### Transparencia de Autoría (Generado con IA)
> Este proyecto fue **desarrollado íntegramente con ayuda de Inteligencia Artificial utilizando el Creador de Apps de Google AI Studio** (*Google AI Studio App Builder*), diseñado bajo una arquitectura modular de código abierto en **PowerShell + WPF/XAML nativo**.
> Se indica de forma explícita para mantener total transparencia con la comunidad: todo el código es legible en texto plano (sin ejecutables `.exe` compilados ni DLLs externas) para que cualquier persona pueda revisarlo, auditarlo, probarlo o modificarlo antes de ejecutarlo en su equipo.

#### Descripción corta sugerida para la sección "About" de GitHub
> `Suite modular de optimización, auditoría de hardware y privacidad para Windows 10/11 en PowerShell + WPF nativo, desarrollada con IA en el Creador de Apps de Google AI Studio.`

---

## ¿Qué es y qué NO es WinForge Engine?

- **Qué SÍ es:** Una herramienta transparente de configuración del sistema para **Windows 10 (Build 19041+)** y **Windows 11 (incluido 24H2+)**. Permite auditar el hardware real del equipo, reducir procesos en segundo plano, limitar telemetría/IA opcional, gestionar aplicaciones de inicio de forma reversible y aplicar perfiles adaptados tanto a **PCs antiguos (Legacy)** como a **equipos modernos**.
- **Qué NO es:** No es un "acelerador mágico" que reemplace componentes físicos ni multiplique FPS artificialmente. Tampoco es una caja negra: cada ajuste muestra la ruta exacta del Registro, servicio o política que toca, su beneficio real, su posible desventaja y su nivel de riesgo (`Bajo`, `Moderado`, `Alto`).
- **Privilegios requeridos:** Solicita permisos de **Administrador (UAC)** porque modificar servicios del sistema, directivas de grupo en `HKLM` y paquetes UWP requiere elevación.
- **Advertencia de Antivirus / SmartScreen:** Al descargarse mediante un script remoto (`irm | iex`) que modifica claves del Registro, Windows Defender o antivirus de terceros pueden mostrar avisos preventivos. Revisa siempre el código fuente en este repositorio antes de ejecutarlo y crea respaldos previos.
- **Responsabilidad:** Aunque WinForge crea Puntos de Restauración y backups `.reg` antes de aplicar cambios, el usuario es responsable de revisar cada ajuste y sus efectos secundarios antes de aplicarlo.

---

## Cómo usar (Ejecución Zero-Install en 1 línea)

WinForge no instala archivos permanentes en el sistema: descarga los scripts en una carpeta temporal volátil (`%TEMP%\WinForge_<GUID>`) y los elimina automáticamente al cerrar el programa (`finally`).

1. Haz clic derecho en el botón de Inicio de Windows y abre **Terminal (Administrador)** o **PowerShell**.
2. Pega y ejecuta el siguiente comando:

```powershell
irm https://raw.githubusercontent.com/olshhhh/Optimizador/main/bootstrap.ps1 | iex
```

3. Acepta la solicitud de **Control de Cuentas de Usuario (UAC)** si aparece.

### Opciones de ejecución en consola (CLI / WinPE / Desatendido)

Si estás en un servidor sin entorno gráfico, en Windows PE o prefieres usar solo teclado en consola:

```powershell
# Abrir menú interactivo en consola (CLI)
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/olshhhh/Optimizador/main/bootstrap.ps1))) -Cli

# Aplicar directamente un perfil en modo consola (Legacy, Gaming, Trabajo, Laptop o Extremo)
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/olshhhh/Optimizador/main/bootstrap.ps1))) -Cli -Profile Legacy
```

### Ejecución local (si descargaste el repositorio como ZIP o con `git clone`)

```powershell
powershell -NoProfile -STA -ExecutionPolicy Bypass -File .\WinForge.ps1
```

---

## Cómo funciona internamente (Paso a paso)

1. **`bootstrap.ps1` (Arranque volátil):** Fuerza `TLS 1.2`, verifica si tienes permisos de Administrador (si no, relanza la sesión con `-STA` y elevación UAC conservando argumentos), descarga los archivos del repositorio a `%TEMP%\WinForge_<GUID>` evitando caché CDN y ejecuta `WinForge.ps1`. Al cerrar la app, el bloque `finally` borra esa carpeta temporal.
2. **`WinForge.ps1` (Orquestador):** Valida si puede cargar WPF (`PresentationFramework`, `PresentationCore`, `WindowsBase`) o si debe cambiar al modo consola (`CliController.psm1`). Importa los módulos en `Core\` y lanza la auditoría inicial.
3. **`Core/HardwareAuditor.psm1` (Auditoría y Guardrails):** Consulta `Get-CimInstance` y cmdlets de almacenamiento (`Get-Partition`, `Get-Disk`, `Get-PhysicalDisk`) —sin usar el obsoleto `Get-WmiObject`— para detectar:
   - Tipo de disco del sistema (`NVMe`, `SSD SATA` o `HDD mecánico`).
   - Memoria RAM total/libre y nivel (`Critical <= 4.5 GB`, `Low <= 8.5 GB`, `Standard`, `High`).
   - Procesador (arquitectura híbrida Intel P-Cores/E-Cores vs CPU estándar o de gama básica).
   - Chasis (`Desktop` vs `Laptop` mediante `Win32_SystemEnclosure` y `Win32_Battery`).
   - Versión exacta de Windows (`BuildNumber` y `DisplayVersion`).
4. **`Core/SafetyManager.psm1` (Respaldo y Rollback):** Antes de aplicar cambios (excepto tareas de mantenimiento en vivo), intenta crear un **Punto de Restauración** (`Checkpoint-Computer`) y exporta automáticamente mediante `reg.exe export` todas las claves del Registro involucradas a:
   `%LOCALAPPDATA%\WinForge\Backups\<YYYYMMDD_HHMMSS>\` junto con un archivo `session_manifest.json`.
5. **`Core/TweakEngine.psm1` (Motor Idempotente):** Antes de aplicar cada ajuste comprueba `detectScript` para no repetir cambios ya aplicados. También gestiona las entradas de inicio (`HKCU` / `HKLM Run`) moviéndolas de forma reversible a `Software\WinForge\DisabledRun` en lugar de borrarlas.
6. **`Core/RunspaceManager.psm1` + `UI/GuiController.psm1` (Interfaz asíncrona):** La ventana WPF (`UI/MainWindow.xaml`) se dibuja con `[System.Windows.Markup.XamlReader]::Parse()` sin librerías de terceros. Todas las operaciones pesadas corren en un `RunspacePool` en segundo plano enviando logs y progreso a través de una cola segura (`ConcurrentQueue`) drenada por un `DispatcherTimer`, evitando que la ventana se congele.

---

## Protección por Hardware (Guardrails) y Niveles de Riesgo

WinForge bloquea automáticamente ajustes peligrosos para tu hardware concreto:

| Regla de Seguridad | Condición Detectada | Acción Automática | Motivo Técnico |
| :--- | :--- | :--- | :--- |
| **Protección SysMain / Search** | Disco `C:` es **HDD mecánico** | **BLOQUEADO** (`PERF_SYSMAIN`, `PERF_SEARCH_INDEXING`) | Desactivar SuperFetch/SysMain en un disco mecánico empeora drásticamente el arranque y la apertura de programas. |
| **Protección de RAM** | Equipo con **<= 8.5 GB de RAM** | **BLOQUEADO** (`PERF_MEM_COMPRESSION_OFF`) | Sin compresión de memoria en RAM justa, Windows pagina en exceso al disco generando tirones severos. |
| **Protección de Portátiles** | Chasis **Laptop / Batería** | **ADVERTENCIA** (`PERF_HYBRID_PCORE`, `PERF_POWER_THROTTLING`, `PERF_HIBERNATE`) | Pide confirmación explícita porque reduce la autonomía de batería o desactiva la hibernación ante batería crítica. |
| **Protección de Build** | Compilación de Windows inferior a `minBuild` | **BLOQUEADO** (ej. menú clásico Win11 o Recall 24H2+ en Win10) | Evita escribir políticas incompatibles con tu versión de Windows. |
| **Windows Update Intacto** | Siempre | **Nunca se deshabilita** `wuauserv` ni se borra `SoftwareDistribution` | Evita dejar el sistema sin parches de seguridad críticos. |

### Niveles de Riesgo mostrados en cada tarjeta
- **`Bajo` (Verde):** Ajustes seguros y fácilmente reversibles (telemetría opcional, timeouts de cierre, caché DNS, ocultamiento de Copilot/Recall).
- **`Moderado` (Naranja):** Cambios notables de comportamiento o hardware (desactivar Hibernación, Indexación, HAGS, Teredo o apps de Xbox).
- **`Alto` (Rojo):** Ajustes avanzados con impacto funcional importante (desactivar Cola de Impresión `Spooler` o Compresión de Memoria).

---

## Perfiles Preconfigurados y Asistente Guiado

Si no quieres elegir ajuste por ajuste, puedes usar el botón **Asistente Guiado** (5 preguntas simples) o cargar uno de los 5 perfiles de `Data/profiles.json`:

| Perfil | Público objetivo | Qué prioriza |
| :--- | :--- | :--- |
| **`PC Antiguo (Legacy)`** | PCs con HDD, <= 8 GB RAM o CPUs básicos | Desactiva transparencias Acrylic/Mica, animaciones, Edge StartupBoost, NTFS LastAccess, telemetría e IA, **manteniendo activo SysMain y Memory Compression**. |
| **`Gaming`** | Equipos orientados a videojuegos | Activa HAGS, prioriza P-Cores en CPUs híbridos, desactiva Game DVR, algoritmo de Nagle, Network Throttling y configura DNS Cloudflare (`1.1.1.1`) **sin eliminar Xbox Apps**. |
| **`Trabajo`** | Ofimática, desarrollo y estudio | Bloquea telemetría, Copilot, Recall IA, sugerencias Bing y apps distractoras, **manteniendo intactas impresoras y búsqueda local**. |
| **`Laptop`** | Portátiles y ultrabooks | Limpia telemetría, IA y procesos superfluos **protegiendo Power Throttling, Hibernación y batería**. |
| **`Extremo`** | Usuarios avanzados en estaciones rápidas | Aplica la mayoría de optimizaciones disponibles (sigue respetando el bloqueo automático de `SysMain` en HDD y `MemoryCompression` en <= 8 GB RAM). |

---

## Respaldos, Logs y Reversión Manual (Rollback)

- **Dentro de la aplicación:** Usa el botón **Revertir Todo** (arriba a la derecha), **Revertir** en cada ajuste, o **2º Plano / Después** para minimizar o dejar pendientes en cola (`%LOCALAPPDATA%\WinForge\pending_queue.json`).
- **Interfaz Monocromática Ligera:** Diseñada sin sombras pesadas (`DropShadowEffect`) y con pinceles congelados para gastar la mínima RAM/GPU en PCs antiguos, con botones nativos para Minimizar y Maximizar, además de un panel inferior de **Actividad y Procesos** en vivo.
- **Respaldos manuales en disco:** Cada sesión guarda archivos `.reg` originales y un manifiesto en:
  ```text
  %LOCALAPPDATA%\WinForge\Backups\<Fecha_Hora>\Registry\
  ```
  Puedes hacer doble clic sobre cualquiera de esos archivos `.reg` en el Explorador de Windows para restaurar la clave exacta original.
- **Registro de errores al arrancar:** Si ocurre algún problema durante la carga inicial, WinForge detiene la ventana para que puedas leer el mensaje y guarda la traza técnica en:
  ```text
  %LOCALAPPDATA%\WinForge\Logs\last_error.log
  ```

---

## Pruebas de Verificación (Test Suite)

El repositorio incluye el script `Tests/Verify-WinForge.ps1` (sin dependencias externas como Pester) para validar de forma segura y en **solo lectura** (sin modificar el Registro ni servicios de tu PC):
1. Que `Data/tweaks.json` y `Data/profiles.json` sean JSON válidos, sin IDs duplicados ni referencias rotas.
2. Que `UI/MainWindow.xaml` y las ventanas emergentes en `UI/GuiController.psm1` se parseen correctamente en WPF.
3. Que todos los módulos `.psm1` se importen sin errores bajo `Set-StrictMode -Version Latest`.
4. Que `Get-WinForgeHardwareProfile` y `Resolve-WinForgeTweakCompatibility` evalúen tu hardware real correctamente.
5. Que los 49 `detectScript` de `Data/tweaks.json` se ejecuten en modo solo lectura sin lanzar excepciones bajo `Set-StrictMode -Version Latest`.

Para ejecutar las pruebas en Windows PowerShell:

```powershell
powershell -NoProfile -STA -ExecutionPolicy Bypass -File .\Tests\Verify-WinForge.ps1
```

---

## Estructura del Repositorio

```text
/
├── bootstrap.ps1                 # Punto de entrada Zero-Install (UAC, TLS 1.2, STA, Bypass temporal)
├── WinForge.ps1                  # Orquestador principal (detección GUI STA vs CLI/WinPE, log de errores)
├── Core/
│   ├── RunspaceManager.psm1      # Motor RunspacePool + cola LogQueue/DispatcherTimer thread-safe
│   ├── HardwareAuditor.psm1      # Telemetría CIM/Storage, Tiering y Guardrails de hardware
│   ├── SafetyManager.psm1        # Puntos de restauración, exportación .reg y motor Rollback
│   └── TweakEngine.psm1          # Carga JSON, ejecución idempotente y Startup Apps reversible
├── UI/
│   ├── MainWindow.xaml           # Interfaz monocromática ligera WPF pura (Minimizar/Maximizar, sin x:Class)
│   ├── GuiController.psm1        # Controlador WPF, Asistente, 2º Plano, Cola Pendientes y Gestor Inicio
│   └── CliController.psm1        # Menú alternativo y Asistente para consolas headless o WinPE
├── Data/
│   ├── tweaks.json               # Catálogo de 49 ajustes documentados con nivel de riesgo
│   └── profiles.json             # Perfiles Legacy, Gaming, Oficina, Laptop y Extremo
├── Tests/
│   └── Verify-WinForge.ps1       # Suite de pruebas automatizadas en modo solo lectura para Windows
├── LICENSE                       # Licencia MIT
└── README.md
```

---

## Licencia

Distribuido bajo licencia **MIT**. Consulta el archivo [`LICENSE`](LICENSE) para más detalles.
