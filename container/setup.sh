#!/usr/bin/env bash
# Build the Kali image, then wrap it in a rootless distrobox.
# Run as YOUR USER, no sudo:   ~/kali/setup.sh
# Override tool set:           METAPACKAGE=kali-linux-large ~/kali/setup.sh
#
# Metapackage ladder, and how much menu you get from each (measured against
# kali-menu 2026.3.2, which ships 539 launchers for Kali's whole catalogue):
#
#   kali-linux-core        ~340 pkgs     ~2 entries    too small to be useful
#   kali-linux-headless  ~1,700 pkgs   ~170 entries   (estimated)
#   kali-linux-default    2,431 pkgs    292 entries   <- default; 12.8 GB image
#   kali-linux-large      2,889 pkgs    436 entries   21.9 GB image, much longer build
#
# The menu only ever lists tools that are actually installed, so a smaller
# metapackage gives a smaller menu rather than a broken one.
set -euo pipefail

# Overridable so a throwaway build can be tested without touching a working one.
NAME="${KALI_NAME:-kali}"
IMAGE="${KALI_IMAGE:-kali-lab:latest}"
META="${METAPACKAGE:-kali-linux-default}"
KHOME="${KALI_HOME:-$HOME/kali/home}"
DIR="$(cd "$(dirname "$0")" && pwd)"

[ "$(id -u)" -eq 0 ] && { echo "do NOT run this with sudo -- this is rootless"; exit 1; }
for c in distrobox podman; do
  command -v $c >/dev/null || { echo "missing $c -> sudo pacman -S --needed distrobox podman"; exit 1; }
done

mkdir -p "$KHOME"

if [ "${KALI_YES:-0}" != 1 ]; then
  echo "Metapackage: $META -- long, hot build on this CPU. Ctrl-C to abort."
  read -rp "Continue? [y/N] " a; [ "${a,,}" = y ] || exit 1
fi

# The JVM cannot work out HiDPI scaling on Wayland, so pass it in. Derive it
# from the focused monitor rather than hardcoding: 2 is right for a 3200x1800
# panel and makes Burp unusable on 1080p.
UI_SCALE="${KALI_UI_SCALE:-}"
if [ -z "$UI_SCALE" ]; then
  UI_SCALE=$(hyprctl -j monitors 2>/dev/null \
    | python3 -c 'import json,sys
try:
    m = json.load(sys.stdin)
except Exception:
    print(1); raise SystemExit
best = max(m, key=lambda d: d.get("height", 0), default=None)
print(2 if best and (best.get("scale", 1) >= 1.5 or best.get("height", 0) >= 1600) else 1)' 2>/dev/null) || UI_SCALE=1
fi
echo "==> [1/3] building $IMAGE (metapackage: $META, uiScale: $UI_SCALE) -- this is the long part"
podman build -t "$IMAGE" -f "$DIR/Containerfile" \
  --build-arg "KALI_UI_SCALE=$UI_SCALE" --build-arg "KALI_METAPACKAGE=$META" "$DIR"

echo "==> [2/3] creating rootless distrobox '$NAME' (isolated home: $KHOME)"
if distrobox list 2>/dev/null | grep -qw "$NAME"; then
  echo "    '$NAME' exists, recreating to pick up the new image"
  distrobox rm --force "$NAME" 2>/dev/null || true
fi
# --unshare-netns is REQUIRED: distrobox defaults to --network host, and
# NET_ADMIN/NET_RAW granted inside a rootless userns do not apply to the
# host netns -- so openvpn's tun creation and nmap -sS both fail with EPERM.
# A private netns makes those caps effective.
distrobox create --yes \
  --name "$NAME" \
  --image "$IMAGE" \
  --home "$KHOME" \
  --unshare-netns \
  --additional-flags "--cap-add=NET_ADMIN --cap-add=NET_RAW --device /dev/net/tun"

echo "==> [3/3] initialising"
distrobox enter --name "$NAME" -- true

# distrobox's first-run init creates ~/.config, ~/.local, ~/.java and friends
# as root inside the user namespace, which lands on the host as an unwritable
# uid. Any tool that wants to write config then dies -- theHarvester, wfuzz,
# hashcat and scapy all fail with PermissionError until this is fixed.
#
# This cannot live in the Containerfile: the home is a host directory
# bind-mounted in after the image is built, so no RUN layer can reach it.
echo "==> fixing ownership of the container home"
distrobox enter --name "$NAME" -- bash -lc \
  'sudo chown -R "$(id -u):$(id -g)" "$HOME" 2>/dev/null; true'

echo
echo "==> done. enter with:  distrobox enter kali   (or ~/kali/kali.sh)"
