# WinForge Engine

Suite modular de optimización, auditoría de hardware, mantenimiento y telemetría para **Windows 10 (Build 19041+)** y **Windows 11**, diseñada bajo tres pilares:

1. **Transparencia Radical:** Cada ajuste documenta exactamente qué componente modifica (`Registro`, `Servicio`, `PoliticaGrupo`, `TareaProgramada`), su ruta exacta, su beneficio real y sus posibles efectos secundarios.
2. **Seguridad por Diseño (Hardware Guardrails):**
   - Auditoría previa vía `Get-PhysicalDisk` y `Get-CimInstance` (`Win32_SystemEnclosure`, `Win32_Battery`).
   - **Regla HDD:** Si la unidad del sistema (`C:`) es un HDD mecánico, bloquea automáticamente la desactivación de **SysMain (SuperFetch)** y ajustes `SSDOnly`.
   - **Regla Laptop:** Alerta en color naranja si un ajuste afecta el consumo energético, *Power Throttling* o la hibernación en equipos portátiles.
   - **Backup & Rollback:** Antes de aplicar cambios crea un Punto de Restauración del Sistema (`Checkpoint-Computer`), exporta las claves `.reg` afectadas a `$env:LOCALAPPDATA\WinForge\Backups\<Timestamp>\` y habilita un botón **Deshacer Todo / Revertir**.
3. **Arquitectura Asíncrona y Zero-Install:**
   - Interfaz WPF nativa en Windows 11 Dark Mode sin librerías de terceros (`XamlReader.Parse`).
   - Ejecución en segundo plano con `RunspacePool` y actualización thread-safe mediante `Dispatcher.Invoke`.
   - Limpieza total de archivos temporales al cerrar el proceso.

---

## Ejecución Zero-Install (Una sola línea)

Abre **PowerShell** (se elevará automáticamente por UAC si es necesario) y ejecuta:

```powershell
irm https://raw.githubusercontent.com/<USER>/<REPO>/main/bootstrap.ps1 | iex
```

### Parámetros opcionales para automatización / CLI / WinPE

```powershell
# Forzar interfaz CLI en consola o entornos headless
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/<USER>/<REPO>/main/bootstrap.ps1))) -Cli

# Aplicar un perfil directamente en modo desatendido
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/<USER>/<REPO>/main/bootstrap.ps1))) -Cli -Profile Laptop
```

---

## Estructura del Repositorio

```text
/
├── bootstrap.ps1                 # Punto de entrada Zero-Install (UAC, TLS 1.2, limpieza en finally)
├── WinForge.ps1                  # Orquestador principal (detección GUI STA vs CLI/WinPE)
├── Core/
│   ├── RunspaceManager.psm1      # Motor RunspacePool + Dispatcher thread-safe
│   ├── HardwareAuditor.psm1      # Telemetría CIM/Storage y Guardrails de hardware
│   ├── SafetyManager.psm1        # Puntos de restauración, exportación .reg y Rollback
│   └── TweakEngine.psm1          # Evaluación idempotente y ejecución de tweaks
├── UI/
│   ├── MainWindow.xaml           # Interfaz Fluent Dark Mode WPF pura (sin x:Class)
│   ├── GuiController.psm1        # Controlador WPF, perfiles y consola asíncrona
│   └── CliController.psm1        # Menú alternativo para consolas headless o WinPE
├── Data/
│   ├── tweaks.json               # Catálogo de ajustes documentados y reversibles
│   └── profiles.json             # Perfiles Gaming, Trabajo, Laptop y Extremo
└── README.md
```

---

## Descargo de Responsabilidad

WinForge Engine modifica configuraciones del sistema operativo, servicios y claves del Registro de Windows bajo estándares idempotentes y con respaldo previo automático. Aunque incluye guardrails estrictos para prevenir errores comunes (como deshabilitar SysMain en discos mecánicos o romper Windows Update), el administrador del equipo es responsable de revisar las advertencias mostradas en pantalla antes de aplicar perfiles avanzados o desinstalar aplicaciones UWP.
