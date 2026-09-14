# Kali Tools for the Omarchy menu

Puts the tools from a Kali [distrobox](https://distrobox.it/) container into the
Omarchy menu, organised the way Kali organises them.

Kali's `kali-menu` package already did the hard part: 539 `.desktop` launchers
with a kill-chain category tree, pointing at a guided wizard where one exists and
`--help` where one doesn't. This reads that out of the container and writes it as
menu rows.

**Only tools you actually have are listed.** `kali-menu` ships launchers for
Kali's entire catalogue, not for what is installed, so on a typical container
about a third of them point at nothing.

## Before you install

**Tested against Omarchy 4.0.2** on x86_64. This reads and writes Omarchy's menu
extension file and relies on specifics of its shell; treat behaviour on other
versions as unverified, and open an issue rather than assuming it is broken by
design.

**It runs commands as you.** Like any Omarchy plugin it is unsandboxed code in
the shell process — `omarchy plugin add` warns about this. Concretely: when the
Kali container is **already running**, it shells out at login to regenerate the
menu. If the container is stopped it does nothing and leaves your last rows in
place; it will not start a 12-22 GB container behind your back.

The generated menu rows also invoke `distrobox` on your behalf when clicked,
which is the entire point, but worth knowing before you enable it.

## Install

```bash
omarchy plugin add https://github.com/gianandr4/omarchy-kali
omarchy plugin enable fygas.kali
```

You need a Kali distrobox with the `kali-menu` package in it. If you have one
already:

```bash
distrobox enter kali -- sudo apt install kali-menu
```

If you don't, `container/setup.sh` builds one (see below). Then:

```bash
~/.config/omarchy/plugins/fygas.kali/bin/kali-menu link   # put the commands on PATH
kali-menu sync                                            # build the rows

# optional: keep the menu in step after `omarchy update`
omarchy hook install post-update ~/.config/omarchy/plugins/fygas.kali/hooks/kali-menu-sync.hook
```

The menu hot-reloads; no restart. Point it at a differently-named container with
`KALI_CONTAINER=<name>`.

## Commands

| | |
|---|---|
| `kali-menu sync` | regenerate the rows |
| `kali-menu doctor` | check the install and say what's wrong |
| `kali-menu uninstall` | remove rows and symlinks — **run before `omarchy plugin remove`** |
| `kali-run 'nmap --help'` | run a tool, then land in a shell with `nmap ` already typed |
| `kali-gui burpsuite` | launch a GUI app from the container |
| `kali-update` | upgrade the container, then resync |
| `kali-update --install btop` | install packages and resync in one step |

Rows are written between sentinel comments in
`~/.config/omarchy/extensions/omarchy-menu.jsonc`; anything you hand-write
outside that block is preserved, and a timestamped backup is kept each run.

## Building a container

```bash
container/setup.sh                                 # kali-linux-default
METAPACKAGE=kali-linux-large container/setup.sh    # everything short of the kitchen sink
```

How much menu each metapackage gives you. The two marked *built* are measured
from real builds of this Containerfile; the others are estimated from apt's
dependency closure and will come out somewhat higher in practice, because the
image also installs `kali-linux-headless` explicitly and apt pulls recommends.

| Metapackage | Packages | Menu entries | Image |
|---|---|---|---|
| `kali-linux-core` | ~340 | ~2 — too small to be useful | |
| `kali-linux-headless` | ~1,700 | ~170 est. | |
| `kali-linux-default` | 2,431 | **298** *(built)* | 12.8 GB |
| `kali-linux-large` | 2,889 | **448** *(built)* | 21.9 GB |

A smaller metapackage gives a smaller menu, not a broken one. `large` roughly
doubles the image for about 50% more tools.

Both measured figures come from one machine, at one point in Kali rolling's
life. Expect them to drift.

## Uninstall

```bash
kali-menu uninstall                  # removes the rows and the symlinks
omarchy plugin remove fygas.kali
```

Run them in that order. `omarchy plugin remove` is an `rm -rf` with no uninstall
hook, so anything outside the plugin directory is yours to clean up. If you
forget, nothing breaks: the generated rows are guarded on the plugin directory
existing, so they disappear from the menu the moment it does.

## Things that cost real time to find

Worth reading if you are doing Kali-in-distrobox at all, with or without this.

**Don't run GUI apps as root in the container.** Debian's
`libpixbufloader_svg.so` links `libglycin`, so every SVG icon in a GTK app is
decoded by a helper inside a `bwrap` sandbox. As root that helper exits 1 and GTK
aborts on the assert in `gtkiconhelper.c` — zenmap builds its entire main window,
then dies with SIGABRT. As your user it is fine. Qt apps are unaffected. Root is
usually unnecessary anyway: with `--cap-add=NET_RAW`, `nmap -sS` works
unprivileged, which is the only reason Kali's launchers wanted root.

**`pkexec` cannot work in the container** — there is no polkit agent, so it hangs
on a prompt nobody can answer. Kali's `pkexec` launchers are rewritten to run as
you. The one exception is `fern-wifi-cracker`, which writes under `/usr/share` and
genuinely needs root; it is Qt, so it tolerates it.

**distrobox's init creates `~/.config` and friends as root**, which lands on the
host as an unwritable uid. theHarvester, wfuzz, hashcat and scapy all die with
`PermissionError` until that is fixed. `setup.sh` fixes it after init — it cannot
be done in the `Containerfile`, because the home is bind-mounted in after the
image is built.

**Purge `rpm` from the image.** distrobox finds both `apt-get` and `rpm`, takes
its ALT Linux code path, tries to install packages that do not exist in Kali, and
init fails with exit 100.

**`--unshare-netns` is required.** distrobox defaults to the host netns, where
`NET_ADMIN`/`NET_RAW` granted in a rootless userns do not apply — so openvpn's
tun creation and `nmap -sS` both fail with EPERM.

**`omarchy plugin remove` runs no uninstall hook**; it is an `rm -rf`. The rows
would outlive the plugin, so the root row is guarded on the plugin directory
still existing — remove the plugin and the tree disappears. `kali-menu uninstall`
cleans up properly.

## Design note

The menu's `provider:` field is **not** a user extension point, despite what the
comment in `omarchy-menu.jsonc` says. `Menu.qml` defines a `readonly` map of
exactly three (`fonts`, `power-profiles`, `apps`); an unknown key is silently a
no-op, rows are tab-delimited rather than JSON, and each provider's action comes
from a QML function. Writing the JSONC is the only path to menu rows, so the rows
are generated rather than served.

## Troubleshooting

```bash
kali-menu doctor            # what is wrong, with a suggested fix per failure
kali-menu doctor --json     # same, machine-readable
kali-menu skill install     # install the troubleshooting skill for Claude Code
```

`skills/omarchy-kali/SKILL.md` documents every failure mode above plus the ones
that are hard to diagnose cold — it is worth reading even if you never use an
agent.

## Verifying

```bash
kali-menu doctor      # the live install
test/regression       # 21 checks, each one a bug this shipped
```

Not covered by either: whether a GUI app actually draws a window, and the handful
of entries that start services. Those need a human.

## Licence

MIT
