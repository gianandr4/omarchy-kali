# Notes for agents working on this repo

Install the troubleshooting skill first — it carries the failure modes, and most
of them are invisible from the outside:

```bash
kali-menu skill install      # copies skills/omarchy-kali into ~/.claude/skills/
```

Or read `skills/omarchy-kali/SKILL.md` directly.

## Orientation

`bin/kali-menu` reads Kali's `kali-menu` package out of a distrobox container
and writes rows into `~/.config/omarchy/extensions/omarchy-menu.jsonc` between
sentinel comments. `KaliMenu.qml` is a `service`-kind Omarchy plugin whose only
job is to run that at login and expose `omarchy-shell kali sync`. `bin/kali-run`
and `bin/kali-gui` are what the generated rows actually invoke.

## Before you change anything

```bash
kali-menu doctor --json     # structured state, with a hint per failed check
test/regression             # 21 checks; every one is a bug this shipped
```

Run the suite after any change to the generator, the wrappers, or the
Containerfile. It is fast apart from the container round-trips.

## The rule that matters most

**Nothing here was found by reading the code.** The provider that does not
exist, the write race that emptied the menu, 195 rows pointing at uninstalled
tools, `sudo` aborting GTK apps, a bind mount that only existed on one machine —
every one surfaced by running something. Two were found by a user clicking a
menu entry.

So: exercise your change, do not reason about it. If you cannot exercise it, say
so plainly rather than claiming it works.

## Invariants

These are load-bearing and each cost a debugging session. The skill explains why.

- `provider:` in the menu JSONC is not a user extension point
- reach the container via `/run/host`, never a `--volume` bind mount
- never write inside the plugin directory (inotify reloads it)
- no symlinks inside the plugin directory (validation rejects the plugin)
- commit scripts `100755`
- menu writes must be atomic
- GUI rows run as the user, never root
- helper scripts resolve to the tool they wrap
