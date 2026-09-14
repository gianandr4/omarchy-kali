---
name: omarchy-kali
description: >
  Troubleshoot Kali tools in the Omarchy menu, and GUI/CLI apps inside a Kali
  distrobox container generally. Use when a menu row does nothing, a Kali GUI
  app exits immediately, the Kali menu is empty or stale, or a tool in the
  container fails with PermissionError. Triggers: kali-menu, kali-run, kali-gui,
  kali-update, fygas.kali, omarchy-menu.jsonc, distrobox, zenmap, burpsuite,
  "Gtk couldn't be initialized", glycin, bwrap, pkexec in a container.
---

# Kali tools in the Omarchy menu

Verified against **Omarchy 4.0.2**. The Omarchy internals described below
(the provider map, plugin lifecycle, menu merge) were read from that version's
source — re-check them before trusting them on a newer one.

Start here: `kali-menu doctor --json`. It reports container state, menu validity,
whether every emitted command resolves, and carries a `hint` per failed check.

Architecture in one line: a generator reads Kali's `kali-menu` package out of a
distrobox container and writes rows into
`~/.config/omarchy/extensions/omarchy-menu.jsonc` between sentinel comments.

## Failure modes, in the order they are likely

### A menu row does nothing at all

Almost always a **GUI row whose app died instantly**. `kali-gui` detaches, so
there is nowhere for an error to print. Reproduce in the foreground:

```bash
distrobox enter kali -- <command>
```

Two causes dominate:

1. **The tool is not installed.** `kali-menu` ships launchers for Kali's whole
   catalogue, not for what is installed — about a third point at nothing on a
   typical container. The generator filters these out, so a dead row means the
   menu is stale: run `kali-menu sync`.
2. **It is a GTK app being run as root.** See below.

### Never run a GTK app as root in the container

Debian's `libpixbufloader_svg.so` links `libglycin`, so every SVG icon in a GTK
app is decoded by a helper inside a `bwrap` sandbox. **As root that helper exits
1** and GTK aborts on the assert in `gtkiconhelper.c` — the app builds its entire
main window, then dies with SIGABRT (exit 134).

```
Gtk:ERROR:.../gtkiconhelper.c:495:ensure_surface_for_gicon: assertion failed
  ... Loader process exited early with status '1'
```

As the user it is fine. **Qt apps are unaffected** — if it survives root, it is Qt.

Do not "fix" this by chasing icon themes, mime caches, bwrap, or seccomp. All
were eliminated: it fails identically with the distro theme, `bwrap` works by
hand, the caches are present, `GLYCIN_SECCOMP_DEFAULT_ACTION` has no effect at
any value, and a container built with `--security-opt seccomp=unconfined` aborts
exactly the same.

Root is usually unnecessary: with `--cap-add=NET_RAW`, `nmap -sS` works
unprivileged, which is the only reason Kali's launchers wanted root.

### "Gtk couldn't be initialized" (a different error)

That is plain `sudo` dropping `WAYLAND_DISPLAY`/`DISPLAY`/`XDG_RUNTIME_DIR`.
`sudo -E` keeps them. But for GTK apps `-E` only gets you as far as the abort
above — the answer is still to not use root.

Measured with `Gtk.init_check()` in-container: user `True`, `sudo` `False`,
`sudo -E` `True`.

### `pkexec` hangs forever

There is no polkit agent in the container, so it waits on a prompt nobody can
answer. The generator rewrites Kali's `pkexec` launchers to run as the user.
`fern-wifi-cracker` is the sole exception — it writes under `/usr/share` and
genuinely needs root; it is Qt, so it tolerates it.

### A `*-start` entry says "System has not been booted with systemd"

distrobox runs systemd as PID 1 but does not boot it: `/run/systemd/system` is
absent and `systemctl is-system-running` returns `offline`. Anything driving a
service fails. Confirm with:

```bash
distrobox enter kali -- bash -lc 'systemctl is-system-running; ls -d /run/systemd/system'
```

The generator drops these rows, detecting them by their call to Kali's
`kali-service-start`/`-stop` helper or to `systemctl`. A presence check cannot
catch them: the tools are installed and the scripts are executable.

They are kept when systemd *is* booted (`distrobox create --init`), which is
checked against the container rather than assumed. If someone reports these
entries missing, ask whether their container uses `--init`.

Do not confuse `iodine-client-start` with this class — it sets up a tunnel
directly and is correctly kept.

### PermissionError from a tool in the container

distrobox's first-run init creates `~/.config`, `~/.local`, `~/.java` as root
inside the user namespace, landing on the host as an unwritable uid. theHarvester,
wfuzz, hashcat and scapy all die this way.

```bash
distrobox enter kali -- bash -lc 'sudo chown -R "$(id -u):$(id -g)" "$HOME"'
```

`container/setup.sh` does this after init. It **cannot** go in the Containerfile:
the home is bind-mounted in after the image is built.

### The menu is empty, or lost hand-written rows

The Omarchy shell hot-reloads `omarchy-menu.jsonc` on change. A **partial write**
is parsed, fails, and silently drops every user row until the shell restarts.
All writes must be atomic (temp file + `os.replace`). If it happens:

```bash
kali-menu sync          # rewrites atomically
omarchy restart shell   # forces a clean parse
```

Backups are kept as `omarchy-menu.jsonc.bak.kali-menu-*`.

### A menu row opens a terminal and "does nothing"

Expected. ~85% of Kali's launchers are `tool --help` — they print usage, then
`kali-run` lands you in a shell **with the command already typed** at the prompt
(readline macro bound to `\e[0n`, triggered by printing `\e[5n`, with
`history -s` as fallback). If the pre-fill does not appear, the terminal did not
answer the status request; press Up instead.

### `kali-update: command not found` inside the container

These commands run on the **host**. They drive distrobox from outside and rewrite
the host's menu file. `distrobox-host-exec` cannot bridge this — it needs
`host-spawn`, which wants the Flatpak D-Bus portal. Use
`kali-update --install <pkgs>` from the host instead of entering the container.

## Which container is in use

Precedence: `KALI_CONTAINER` in the environment, then
`~/.local/state/omarchy-kali/container` (written by `kali-menu use`), then `kali`.
All four commands implement this, two of them in bash and two in Python — change
one and change them all.

The state file is deliberately outside the plugin directory: inotify watches that
tree and any write there reloads the plugin.

## Invariants — do not break these

- **`provider:` is not a user extension point.** `Menu.qml` defines a `readonly`
  map of exactly three (`fonts`, `power-profiles`, `apps`); an unknown key is a
  silent no-op, rows are tab-delimited not JSON, and actions come from a QML
  function. Writing the JSONC is the only path to menu rows.
- **Reach the container via `/run/host`**, never a `--volume` bind mount. Only
  `/run/host` exists on every distrobox.
- **Never write inside the plugin directory** — inotify watches it recursively
  and any write reloads the plugin. Temp work goes to `/tmp`.
- **No symlinks inside the plugin directory** — validation rejects the whole
  plugin. Symlinks into `~/.local/bin` are fine.
- **Commit scripts `100755`.** A `100644` arrives non-executable from a clone.
- **Sync only when the container is already running.** `podman container exists`
  is true for a *stopped* container, and syncing shells out to `distrobox enter`,
  which would start it — a 12-22 GB container spun up at every login for nothing.
  Gate on `podman container inspect -f '{{.State.Running}}'` instead.
- **`omarchy plugin remove` runs no uninstall hook**; it is an `rm -rf`. The root
  row is guarded on the plugin directory existing so rows vanish on removal.
  `kali-menu uninstall` cleans up properly and must run first.
- **Presence is not function.** A launcher can be installed and executable and
  still be impossible — the systemd service entries are the example. When adding
  a filter, ask what makes the row *work*, not what makes it *exist*.
- **Helper scripts must be resolved to the tool they wrap.** They stay executable
  when that tool is absent — `havoc.sh` is the live example. Beware quoted pipes
  (`hydra.sh`) and command substitution (`wireshark.sh`) when parsing them.

## Verifying a change

```bash
kali-menu doctor --json     # live install
test/regression             # 21 checks, each one a bug this shipped
```

Neither covers whether a GUI app actually draws a window, or the entries that
start services. Those need a human.
