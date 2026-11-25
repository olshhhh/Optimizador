# WinForge Engine (`olshhhh/Optimizador`)

> ## Transparencia, Seguridad y Descargo de Responsabilidad
>
> **¿Qué es y qué NO es esta herramienta?**
> - **Código abierto 100% legible:** escrito íntegramente en PowerShell y WPF nativo, sin ejecutables compilados (`.exe`), sin DLLs externas y sin recolección de datos.
> - **No es software milagroso:** no reemplaza hardware antiguo ni multiplica FPS artificialmente; su objetivo es reducir procesos en segundo plano, telemetría y carga innecesaria según el hardware real del equipo (HDD/SSD, RAM y Laptop/Desktop).
> - **Requiere privilegios de Administrador** porque modifica claves del Registro, servicios de Windows, directivas locales y paquetes UWP.
> - **Seguridad y Reversión:** antes de aplicar modificaciones crea automáticamente un Punto de Restauración del Sistema (si el servicio VSS está activo) y exporta respaldos `.reg` en `%LOCALAPPDATA%\WinForge\Backups\<Timestamp>\`. Aun así, **el usuario asume la responsabilidad** de revisar el nivel de riesgo (`Bajo`, `Moderado`, `Alto`) y las desventajas indicadas en cada ajuste antes de aplicarlo.
> - **Advertencia de Antivirus / SmartScreen:** al ejecutarse de forma remota (`irm | iex`) y modificar el Registro, Windows Defender o antivirus de terceros pueden mostrar alertas preventivas. Se recomienda auditar siempre el código fuente en este repositorio antes de ejecutarlo.

---

Suite modular de optimización adaptativa, auditoría de hardware, mantenimiento y privacidad para **Windows 10 (Build 19041+)** y **Windows 11 (incluyendo 24H2+)**. Diseñada para proteger tanto **equipos antiguos (Legacy)** como **estaciones modernas** mediante un motor de reglas de hardware y ejecución asíncrona.

---

## Ejecución Zero-Install (Una sola línea)

Abre **PowerShell** o **Terminal de Windows** (solicitará elevación UAC automáticamente) y ejecuta:

```powershell
irm https://raw.githubusercontent.com/olshhhh/Optimizador/main/bootstrap.ps1 | iex
```

### Parámetros opcionales para automatización / CLI / WinPE

```powershell
# Forzar interfaz CLI en consola o entornos headless
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/olshhhh/Optimizador/main/bootstrap.ps1))) -Cli

# Aplicar un perfil directamente en modo desatendido (Legacy, Gaming, Trabajo, Laptop, Extremo)
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/olshhhh/Optimizador/main/bootstrap.ps1))) -Cli -Profile Legacy
```

---

## Pilares de Ingeniería

1. **Transparencia Radical y Niveles de Riesgo:** Cada ajuste documenta qué componente modifica (`Registro`, `Servicio`, `PoliticaGrupo`, `TareaProgramada`), su ruta exacta, beneficio real, posible desventaja y nivel de riesgo (`Bajo`, `Moderado`, `Alto`).
2. **Asistente Guiado Paso a Paso:** Responde 5 preguntas simples sobre tu uso diario, privacidad 24H2+, impresoras y DNS; WinForge construye automáticamente una selección segura adaptada a tu equipo.
3. **Inteligencia Adaptativa (PC Antiguo vs Moderno):**
   - **Equipos Antiguos (Legacy):** Reduce carga DWM (`EnableTransparency = 0`, `MinAnimate = 0`), activa `NtfsDisableLastAccess = 1` y bloquea procesos residentes de Edge/Copilot, **protegiendo** `SysMain` en discos HDD y **bloqueando** la desactivación de `MemoryCompression` en equipos con `<= 8 GB RAM`.
   - **Equipos Modernos / 24H2+:** Soporte para `HAGS` (`HwSchMode = 2`), prioridad de `P-Cores` en CPUs híbridos (`HETEROPOLICY = 3`), bloqueo de `Windows Copilot` y `Windows Recall / AI Data Analysis`, `Delivery Optimization P2P` y DNS rápidos (`Cloudflare 1.1.1.1` / `AdGuard`).
4. **Gestor Reversible de Apps de Inicio (Startup):** Permite desactivar y reactivar entradas de inicio en `HKCU`/`HKLM Run` moviéndolas de forma segura sin perder sus comandos originales.
5. **Seguridad y Rollback Total:** Crea Punto de Restauración (`Checkpoint-Computer`), exporta respaldos `.reg` en `$env:LOCALAPPDATA\WinForge\Backups\<Timestamp>\` y ofrece **Deshacer Todo / Revertir**.
6. **Arquitectura Asíncrona:** Interfaz WPF Dark Mode nativa sin librerías externas (`XamlReader.Parse`) + `RunspacePool` + limpieza volátil en `finally`.

---

## Estructura del Repositorio

```text
/
├── bootstrap.ps1                 # Punto de entrada Zero-Install (UAC, TLS 1.2, limpieza en finally)
├── WinForge.ps1                  # Orquestador principal (detección GUI STA vs CLI/WinPE)
├── Core/
│   ├── RunspaceManager.psm1      # Motor RunspacePool + Dispatcher thread-safe
│   ├── HardwareAuditor.psm1      # Telemetría CIM/Storage, Tiering y Guardrails
│   ├── SafetyManager.psm1        # Puntos de restauración, exportación .reg y Rollback
│   └── TweakEngine.psm1          # Evaluación idempotente, tweaks y Startup Apps
├── UI/
│   ├── MainWindow.xaml           # Interfaz Fluent Dark Mode WPF pura (sin x:Class)
│   ├── GuiController.psm1        # Controlador WPF, Asistente Guiado y Startup Manager
│   └── CliController.psm1        # Menú alternativo para consolas headless o WinPE
├── Data/
│   ├── tweaks.json               # Catálogo de ajustes documentados con nivel de riesgo
│   └── profiles.json             # Perfiles Legacy, Gaming, Trabajo, Laptop y Extremo
├── LICENSE                       # Licencia MIT
└── README.md
```

---

## Licencia

Distribuido bajo licencia **MIT**. Consulta el archivo [`LICENSE`](LICENSE) para más detalles.
