# CopyCrow

[English](README.md) | **Español**

[![Versión](https://img.shields.io/badge/version-1.3.1-blue.svg)](https://github.com/morphilab/copycrow)
[![Licencia](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)
[![Bash](https://img.shields.io/badge/bash-4.2%2B-orange.svg)](https://www.gnu.org/software/bash/)
[![Pruebas](https://img.shields.io/badge/tests-252%2F252%20passing-brightgreen.svg)](tests/)
[![ShellCheck](https://img.shields.io/badge/shellcheck-0%20issues-brightgreen.svg)](.shellcheckrc)

Sistema de backups automáticos y manuales basado en **Borg Backup**, con interfaz de terminal (TUI) y timers nativos de **systemd**.

> 100 % Bash. Sin runtime de Python/Node; requiere Borg, whiptail, systemd y
> `flock` de util-linux (además de herramientas opcionales para la sincronización
> en la nube y el almacenamiento de la passphrase).

**Desarrollador:** [morphilab](https://github.com/morphilab)

## Características

- **Backups manuales y automáticos** — locales o remotos vía SSH
- **Cifrado client-side** con Borg (`repokey`)
- **Deduplicación** — solo se almacenan los cambios entre backups
- **Retención configurable** por job (diaria, semanal, mensual)
- **Interfaz TUI** con `whiptail` para explorar y extraer backups (el menú cubre las acciones del día a día; `init`, `verify-all` y `auto` son solo por CLI)
- **Automatización nativa** con `systemd --user timers` (sin daemon propio)
- **Logs JSON detallados** con timestamps, estado/códigos de salida y contexto del comando cuando aplica
- **Sin credenciales en el código** — SSH usa `~/.ssh/config`; la sincronización en la nube usa el keyring de la CLI de Proton
- **`BORG_PASSPHRASE` nunca toca el disco** — los timers reciben `BORG_PASSCOMMAND` (más configuración no secreta); nunca incrustes la passphrase en ese comando
- **Bloqueo de archivos (atómico)** — evita ejecuciones concurrentes de backup/verify/sync del mismo job
- **Captura de señales** — limpieza automática con Ctrl+C / SIGTERM / SIGHUP
- **Validación de configuración** — valores validados fail-fast al cargar (anti-inyección, listas blancas); campos requeridos comprobados antes de operar sobre jobs
- **Modo dry-run** — `./copycrow.sh dryrun <job>` simula sin crear un backup ni escribir logs
- **Verificación del repositorio** — `verify <job>` / `verify-all` ejecutan `borg check` (consistencia de repositorio/archivos; la verificación completa de datos requiere `--verify-data`)
- **Notificaciones de fallo** — hook opcional `[global] on_failure_cmd` que se dispara cuando falla un backup o la verificación de un repositorio
- **Comprobación de salud** — `doctor` preflight de borg (local/remoto), SSH, estrategia de passphrase, linger, sesión de systemd, espacio en disco, permisos de directorios y Proton Drive (binario, wrapper de D-Bus, sesión) cuando hay sincronización en la nube configurada
- **Retención de logs** — `[global] logs_retention_days` purga automáticamente logs JSON antiguos (por defecto 30)
- **Autocompletado de Bash** — comandos, nombres de jobs y hosts (`completions/copycrow.bash`)

## ⚠️ Divulgación sobre IA

Este proyecto se desarrolló con ayuda de herramientas de inteligencia artificial. Dada la naturaleza automatizada de algunos componentes, se recomienda a los usuarios revisar y probar el código de forma independiente antes de integrarlo en sus propios sistemas.

## Requisitos

| Dependencia  | Instalación                          |
|-------------|---------------------------------------|
| `borgbackup` | `sudo apt install borgbackup`        |
| `whiptail`  | `sudo apt install whiptail`          |
| `bash` 4.2+ | Incluido en Ubuntu/Debian            |
| `systemd`   | Incluido en Ubuntu/Debian            |
| `util-linux` (`flock`) | Incluido en Ubuntu/Debian   |
| `pass` (recomendado) | `sudo apt install pass`       |

Versiones de Borg verificadas con la suite end-to-end completa: **1.2.4** y **1.4.4**.
La CI instala el paquete `borgbackup` de la distribución; el workflow no fija su
versión.

## Instalación

```bash
git clone https://github.com/morphilab/copycrow.git
cd copycrow
./copycrow.sh init
```

Esto crea `copycrow.conf` (tu configuración) a partir del ejemplo.

## Configuración

### 1. Configurar SSH (solo para backups remotos)

Crea una clave dedicada y configura dos alias:

```bash
ssh-keygen -t ed25519 -f ~/.ssh/copycrow_server -N "" -C "copycrow"
ssh-copy-id -i ~/.ssh/copycrow_server.pub user@1xx.1xx.1.1xx
```

Edita `~/.ssh/config`:

```
Host nas-backup
    HostName 1xx.1xx.1.1xx
    User backupuser
    IdentityFile ~/.ssh/id_ed25519          # tu clave diaria

Host nas-backup-borg
    HostName 1xx.1xx.1.1xx
    User backupuser
    IdentityFile ~/.ssh/copycrow_server     # clave dedicada sin passphrase
```

En `copycrow.conf` usa `host = nas-backup-borg`. Consulta la sección [Seguridad](#seguridad).

### 2. Configurar la passphrase de Borg

```bash
sudo apt install pass
gpg --gen-key                              # genera una clave GPG
pass init "your-gpg-id"                    # inicializa pass
pass insert copycrow/borg                  # guarda la passphrase
export BORG_PASSCOMMAND="pass show copycrow/borg"
```

Añádelo a `~/.bashrc` para que persista.

### 3. Editar `copycrow.conf`

```conf
[global]
retention_default = --keep-daily 7 --keep-weekly 4 --keep-monthly 6
compression = lz4
mount_dir = .mnt
logs_dir = logs
# timeout_start_sec = infinity        # opcional; por defecto 3600 (1 h)

[daily_job]
type = automatic
sources = /home /etc
host = nas-backup-borg
remote_path = /backups/copycrow/daily
schedule = daily
retention = --keep-daily 7 --keep-weekly 4
```

`sources` es una lista de rutas **literales** separadas por espacios: sin
expansión de wildcards/globs y sin `~` (escribe la ruta completa); un token que
empiece por `-` se rechaza para que nunca llegue a Borg como opción. Para hacer
backup de un conjunto dinámico de rutas, lístalas explícitamente (o genera el
conf).

### 4. Usar un archivo de configuración distinto

Todos los comandos que leen configuración respetan la variable de entorno
`COPYCROW_CONF` (por defecto: `<copycrow-root>/copycrow.conf`), así que las
configuraciones alternativas pueden vivir en cualquier sitio:

```bash
COPYCROW_CONF=~/configs/copycrow-test.conf ./copycrow.sh backup test_job
```

`init` es la excepción de bootstrap: siempre apunta a
`<copycrow-root>/copycrow.conf`, creándolo desde el ejemplo si falta (nunca
sobrescribe un archivo existente). Usa `COPYCROW_CONF` con el resto de comandos
para apuntar a otro archivo.

`install` registra la ruta activa en las units generadas (cuando difiere de la
predeterminada), de modo que los timers siguen leyendo el mismo archivo desde el que
instalaste — volver a ejecutar `install` con otro `COPYCROW_CONF` re-apunta los
timers.

## Seguridad

### Clave SSH dedicada para backups

Crea una clave **sin passphrase** para la automatización y conserva tu clave
diaria con passphrase. Usa dos alias SSH al mismo servidor:

```bash
ssh-keygen -t ed25519 -f ~/.ssh/copycrow_server -N "" -C "copycrow"
ssh-copy-id -i ~/.ssh/copycrow_server.pub user@server
```

En `~/.ssh/config`:

```
Host my-server
    HostName 1xx.1xx.1.1xx
    User user
    IdentityFile ~/.ssh/id_ed25519          # clave diaria con passphrase

Host my-server-borg
    HostName 1xx.1xx.1.1xx
    User user
    IdentityFile ~/.ssh/copycrow_server     # clave dedicada sin passphrase
```

En `copycrow.conf` usa `host = my-server-borg`.

### Restringir la clave en el servidor (recomendado)

En el archivo `~/.ssh/authorized_keys` del servidor, restringe la clave a ejecutar
solo borg:

```
command="borg serve --restrict-to-path /path/backups",no-port-forwarding,no-pty ssh-ed25519 AAA...
```

### Passphrase de Borg con `pass` (recomendado)

`pass` cifra la passphrase con GPG. Evita texto plano en `~/.bashrc`:

```bash
sudo apt install pass
gpg --gen-key                              # genera una clave GPG
pass init "your-gpg-id"                    # inicializa
pass insert copycrow/borg                  # guarda la passphrase
export BORG_PASSCOMMAND="pass show copycrow/borg"
```

Añádelo a `~/.bashrc` para que persista. Copycrow propaga `BORG_PASSCOMMAND` a
los timers automáticamente.

> **Nota:** copycrow nunca escribe tu passphrase en disco. Si solo está definida
> `BORG_PASSPHRASE`, los timers automáticos se negarán a persistirla y los backups
> fallarán hasta que configures `BORG_PASSCOMMAND`. Ejecutar
> `./copycrow.sh uninstall` elimina el archivo de entorno generado.

### ssh-agent para claves SSH con passphrase

```bash
eval "$(ssh-agent -s)"
ssh-add ~/.ssh/id_ed25519
```

## Uso

```bash
./copycrow.sh                       # Abrir el menú interactivo (TUI)
./copycrow.sh init                  # Configuración inicial
./copycrow.sh backup <job>          # Backup manual de un job
./copycrow.sh manual <job>          # Alias de backup
./copycrow.sh auto <job>            # Backup automático (usado por los timers)
./copycrow.sh dryrun <job>          # Simular backup (no se crea ningún backup)
./copycrow.sh list [job]            # Listar backups (todos los hosts, o el host de un job)
./copycrow.sh open <host> <arch>    # Extraer y abrir un contenedor
./copycrow.sh verify <job>          # Comprobación de integridad del repositorio (borg check)
./copycrow.sh verify-all            # Verificar todos los repositorios configurados
./copycrow.sh sync <job>            # Replicar un repositorio local a Proton Drive
./copycrow.sh doctor                # Comprobación de salud del sistema en un paso
./copycrow.sh migrate               # Convertir una configuración heredada a inglés v1.0.0
./copycrow.sh install               # Instalar timers de systemd
./copycrow.sh uninstall             # Eliminar los timers
./copycrow.sh status                # Estado del sistema
./copycrow.sh --version             # Mostrar la versión
./copycrow.sh help                  # Ayuda
```

## Comprobaciones de salud y notificaciones

**Verificar repositorios (`borg check`):**
```bash
./copycrow.sh verify daily_job      # comprobación de integridad puntual
```
Añade `verify_schedule = monthly` a `[global]` y ejecuta `install` para obtener
un `copycrow-verify.timer` que comprueba todos los repositorios configurados
según un calendario.

`verify` ejecuta `borg check --info`. Eso valida la consistencia del repositorio
y de los archivos, pero no pasa `--verify-data`: la verificación criptográfica
completa de los datos requiere ejecutar `borg check --verify-data` manualmente.

Cada comprobación se ejecuta bajo el lock del propio job, así que nunca se
intercala con un backup en curso: `verify <job>` se niega a arrancar mientras el
job está ocupado, y `verify-all` (o el timer programado) **salta** los jobs
ocupados con un aviso `skipping verification` — nunca se cuenta como fallo.

**Recibir notificación cuando falla un backup:**
```ini
[global]
on_failure_cmd = notify-send copycrow-backup-failed
```
El valor del hook se **divide por espacios y se ejecuta directamente — sin
shell**: las comillas NO se interpretan, así que un único argumento no puede
contener espacios. Para algo más complejo, apúntalo a un script:
```ini
on_failure_cmd = /usr/local/bin/copycrow-on-failure
```
El hook recibe contexto mediante variables de entorno:
`COPYCROW_FAILED_JOB`, `COPYCROW_FAILURE_ARCHIVE`, `COPYCROW_FAILURE_EXIT_CODE`.
Un hook que falla se registra en el log pero nunca altera el resultado del
backup. Un repositorio que `verify-all` no puede bloquear se cuenta como fallo
de verificación pero no invoca el hook.

**Mantener los logs bajo control:** `logs_retention_days = 30` en `[global]`
purga `logs/copycrow-*.log` con más de N días automáticamente después de cada
backup.

## Backups offsite en Proton Drive (opcional)

CopyCrow puede replicar cualquier repositorio **local** (`host = local`) a
[Proton Drive](https://proton.me/drive) inmediatamente después de cada backup
correcto, usando la CLI oficial
[`proton-drive`](https://proton.me/support/drive-cli) de Proton. Tus datos
obtienen dos capas de cifrado independientes: Borg client-side más el E2E de
Drive.

### Configuración inicial

```bash
# Soporte de keyring + sesión D-Bus (lo necesita la CLI)
sudo apt install libsecret-1-0 dbus-x11

# Descarga el binario de Linux desde https://proton.me/download/drive/cli
chmod +x proton-drive && sudo mv proton-drive /usr/local/bin/

# Inicia sesión una vez (se abre el navegador; la sesión se guarda en el keyring del SO)
dbus-run-session -- proton-drive auth login
```

### Configuración

```ini
[global]
# Opcional, solo si el binario no está en PATH:
# cloud_cli_path = /usr/local/bin/proton-drive

[local_job]
host = local
remote_path = /mnt/external-backup/copycrow
# La PRESENCIA de esta clave habilita la réplica offsite para el job:
cloud_remote = /Backups/local_job
```

Cada `backup` de ese job termina ahora con una subida incremental: un
manifiesto local (`~/.cache/copycrow/cloud/<job>.manifest`, tamaño+mtime)
detecta los archivos sin cambios, así que solo viajan los segmentos
nuevos/reescritos del repositorio. Reintento e inspección manual:

```bash
./copycrow.sh sync <job>   # reintentar/forzar la replicación
./copycrow.sh doctor       # valida binario, wrapper de D-Bus y sesión
```

### Notas y limitaciones

* Se soportan máquinas headless y timers de systemd: cuando no hay sesión
  gráfica (`DISPLAY`/`WAYLAND_DISPLAY` sin definir), cada llamada a la CLI se
  envuelve automáticamente en `dbus-run-session`. Mantén instalados
  `libsecret-1-0` y `dbus-x11`, y el keyring de login desbloqueado.
* La primera sincronización sube todo el repositorio (~1 petición API por
  archivo); considera `timeout_start_sec = infinity` para repositorios grandes.
* Los archivos que Borg elimina al podar NO se borran aún en remoto (la CLI
  oficial no tiene un delete fiable); el uso remoto crece poco a poco con el
  tiempo.
* Restaurar en otro sitio: descarga la carpeta `cloud_remote` con cualquier app
  de Proton y luego apunta borg a la carpeta descargada como un repositorio
  normal.

## Autocompletado

```bash
# Ad hoc:
source completions/copycrow.bash

# Persistente:
mkdir -p ~/.local/share/bash-completion/completions
cp completions/copycrow.bash ~/.local/share/bash-completion/completions/copycrow
```
Completa comandos, nombres de jobs (desde `COPYCROW_CONF`,
`COPYCROW_ROOT/copycrow.conf` o `./copycrow.conf`) y hosts SSH.

## Estructura del proyecto

```
copycrow/
├── copycrow.sh              ← punto de entrada
├── copycrow.conf            ← tu configuración (ignorada por git)
├── copycrow.conf.example    ← configuración de ejemplo
├── README.md
├── README.es.md             ← traducción al español
├── LICENSE
├── CHANGELOG.md
├── SECURITY.md
├── VERSION
├── .gitignore
├── .shellcheckrc
├── .github/
│   └── workflows/ci.yml     ← CI (shellcheck, pruebas, smokes)
├── src/
│   ├── config-parser.sh     ← parser INI + validación
│   ├── safety.sh            ← traps, locks, limpieza
│   ├── backup-core.sh       ← wrapper de Borg + logs JSON
│   ├── timer-generator.sh   ← timers de systemd
│   ├── doctor.sh            ← comprobación de salud
│   ├── tui.sh               ← menús whiptail
│   └── cloud-sync.sh        ← réplica offsite en Proton Drive
├── completions/
│   └── copycrow.bash        ← autocompletado de bash
├── tests/                   ← pruebas bats-core
│   ├── backup-core.bats
│   ├── cli.bats
│   ├── cloud-sync.bats
│   ├── completions.bats
│   ├── config-parser.bats
│   ├── doctor.bats
│   ├── safety.bats
│   ├── timer-generator.bats
│   ├── tui.bats
│   ├── integration-borg.bats
│   └── integration-extract.bats
├── .mnt/                    ← extracción temporal
├── .locks/                  ← locks de exclusión mutua
└── logs/                    ← logs JSON diarios
```

## Pruebas

```bash
# Requiere: bats-core (https://github.com/bats-core/bats-core)
sudo apt install bats
bats tests/
# Las suites de integración (integration-*.bats) usan borg REAL: se
# auto-saltan cuando `borg` no está instalado.
```

## Linting

```bash
shellcheck -x copycrow.sh src/*.sh completions/copycrow.bash
```

## Timers automáticos

```bash
./copycrow.sh install
```

Esto crea timers de `systemd --user` para todos los jobs con `type=automatic`.

**Importante:** los timers de usuario solo se ejecutan cuando hay una sesión de
login activa. Para ejecución siempre activa (incluso sin login):

```bash
loginctl enable-linger
```

## Solución de problemas

**"Permission denied (publickey)"**
- Comprueba que `~/.ssh/config` tenga el `IdentityFile` correcto para ese host
- Si usas una clave con passphrase, desbloquéala con `ssh-add`
- Prueba la clave en el servidor: `ssh user@host "echo ok"`

**"Is borg working on the server?"**
Borg no está instalado en el servidor remoto:
```bash
ssh host "sudo apt install borgbackup"
```

**"A passphrase is needed to encrypt the repository" (en los timers automáticos)**
Necesitas `BORG_PASSCOMMAND` configurado — `BORG_PASSPHRASE` por sí sola nunca se
persiste en disco (por diseño). Consulta la sección [Seguridad](#seguridad).

**Prompts de passphrase en los timers (sin passphrase configurada)**
Los timers no pueden responder prompts interactivos. Configura la passphrase con
`pass` + `BORG_PASSCOMMAND` (consulta [Seguridad](#seguridad)).

**"The repository exists but cannot be opened (wrong passphrase or key material)"**
El repositorio está bien — las credenciales proporcionadas no pueden abrirlo.
Comprueba que `BORG_PASSCOMMAND` devuelve la passphrase correcta (los timers
nunca preguntan), o ejecuta el mismo comando una vez desde un shell donde puedas
introducirla interactivamente.

**"Repository does not exist"**
El repositorio se inicializa automáticamente en el primer backup. Si falla,
comprueba:
- Conexión SSH al host: `ssh host "echo ok"`
- Borg instalado en el servidor remoto
- Permisos de escritura en `remote_path`

**"Configuration file not found: <path>"**
```bash
./copycrow.sh init
```

**Los timers no se ejecutan**
```bash
systemctl --user list-timers 'copycrow-*'
loginctl enable-linger
```

**La clave SSH con passphrase falla en los timers**
Los timers se ejecutan fuera de tu sesión de login: no hay `ssh-agent` y el
`SSH_AUTH_SOCK` efímero no se persiste (queda obsoleto tras un reinicio).
Opciones:
- Usa una clave dedicada sin passphrase para los backups (consulta
  [Seguridad](#seguridad)), o
- Expón un agente a la sesión de systemd del usuario (un `ssh-agent.service` a
  nivel de usuario, más `AddKeysToAgent yes` en `~/.ssh/config`).

**"¿Claves de configuración desconocidas tras actualizar?"**
Si actualizaste desde una versión anterior con claves de configuración en
español:
```bash
./copycrow.sh migrate    # Convierte la configuración al formato inglés v1.0.0
```
Se guarda un backup como `copycrow.conf.bak` cuando el archivo cambia realmente;
si ya está en inglés, el `.bak` temporal se elimina.

## Licencia

MIT — Consulta el archivo `LICENSE`.
