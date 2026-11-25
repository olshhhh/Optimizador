# WinForge Engine (`isaacrietman/Optimizador`)

Suite modular de optimización adaptativa, auditoría de hardware, mantenimiento y privacidad para **Windows 10 (Build 19041+)** y **Windows 11 (incluyendo 24H2+)**. Combina la experiencia guiada e intuitiva inspirada en **APBOptimizer / WinUtil** con un motor de seguridad de hardware para proteger tanto **equipos antiguos (Legacy)** como **estaciones modernas**.

---

## Ejecución Zero-Install (Una sola línea)

Abre **PowerShell** (se elevará automáticamente por UAC si es necesario) y ejecuta:

```powershell
irm https://raw.githubusercontent.com/isaacrietman/Optimizador/main/bootstrap.ps1 | iex
```

### Parámetros opcionales para automatización / CLI / WinPE

```powershell
# Forzar interfaz CLI en consola o entornos headless
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/isaacrietman/Optimizador/main/bootstrap.ps1))) -Cli

# Aplicar un perfil directamente en modo desatendido (Legacy, Gaming, Trabajo, Laptop, Extremo)
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/isaacrietman/Optimizador/main/bootstrap.ps1))) -Cli -Profile Legacy
```

---

## Pilares de Ingeniería y Mejoras Clave

1. **Transparencia Radical y Niveles de Riesgo:** Cada ajuste muestra exactamente qué componente modifica (`Registro`, `Servicio`, `PoliticaGrupo`, `TareaProgramada`), su ruta exacta, beneficio real, desventaja y nivel de riesgo (`Bajo`, `Moderado`, `Alto`).
2. **Asistente Guiado Paso a Paso (Modo APBOptimizer):** Responde 5 preguntas simples sobre tu uso diario, privacidad 24H2+, impresoras y DNS; WinForge construye una selección segura adaptada a tu hardware.
3. **Inteligencia Adaptativa (PC Antiguo vs Moderno):**
   - **Equipos Antiguos (Legacy):** Perfil dedicado que reduce carga DWM (`EnableTransparency = 0`, `MinAnimate = 0`), activa `NtfsDisableLastAccess = 1` y bloquea procesos residentes de Edge/Copilot, **protegiendo** `SysMain` en discos HDD y **bloqueando** la desactivación de `MemoryCompression` en equipos con `<= 8 GB RAM`.
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
└── README.md
```

---

## Descargo de Responsabilidad

WinForge Engine modifica configuraciones del sistema operativo, servicios y claves del Registro de Windows bajo estándares idempotentes y con respaldo previo automático. El administrador del equipo es responsable de revisar las advertencias mostradas en pantalla antes de aplicar ajustes de riesgo moderado o alto.
