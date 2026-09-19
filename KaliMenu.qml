import QtQuick
import Quickshell
import Quickshell.Io

// Keeps the Kali menu rows in step with the container.
//
// The rows themselves live in ~/.config/omarchy/extensions/omarchy-menu.jsonc,
// because that file and the packaged defaults are the only two sources the menu
// reads -- there is no plugin-to-menu bridge. So this service's job is simply to
// run the generator at the right moments; `bin/kali-menu` does the real work.
Item {
  id: root

  // Injected by the shell for any property a plugin declares. `manifest`
  // carries __sourceDir, which is the only exposure of the plugin's own path
  // and the reason the scripts can be found at all.
  property var manifest: null
  property var shell: null

  readonly property string pluginDir: manifest && manifest.__sourceDir ? manifest.__sourceDir : ""
  readonly property string cli: pluginDir ? pluginDir + "/bin/kali-menu" : ""

  function sync(reason) {
    if (!cli || syncProc.running)
      return
    syncProc.reason = reason
    syncProc.command = ["bash", "-lc", "'" + cli + "' sync"]
    syncProc.running = true
  }

  Process {
    id: syncProc
    property string reason: ""
    stdout: StdioCollector {}
    stderr: StdioCollector {}
    onExited: function (code) {
      if (code !== 0)
        console.warn("kali: sync (" + reason + ") failed with " + code)
    }
  }

  // Only sync when the container is already RUNNING -- not merely present.
  //
  // `podman container exists` returns 0 for a stopped container, and syncing
  // shells out to `distrobox enter`, which would start it. That means a 12-22 GB
  // container spun up on every login purely to refresh a menu. Nothing is gained
  // by it either: the rows are static, so the ones from the last sync are still
  // correct until the container's package set changes.
  //
  // No dependency mechanism exists for plugins, so distrobox's absence has to be
  // discovered here rather than declared.
  Process {
    id: preflight
    command: ["bash", "-lc",
      "command -v distrobox >/dev/null || exit 1; " +
      // distrobox autodetects its container manager; hardcoding podman means
      // this never fires on a docker-based machine.
      "m=${DBX_CONTAINER_MANAGER:-}; " +
      "[ -n \"$m\" ] || for c in podman podman-launcher docker lilipod; do " +
      "command -v \"$c\" >/dev/null && { m=$c; break; }; done; " +
      "[ -n \"$m\" ] || exit 1; " +
      "[ \"$(\"$m\" container inspect -f '{{.State.Running}}' \"${KALI_CONTAINER:-kali}\" 2>/dev/null)\" = true ]"]
    onExited: function (code) {
      if (code === 0)
        root.sync("startup")
    }
  }

  // Lets `omarchy-shell kali sync` refresh the menu without a terminal.
  IpcHandler {
    target: "kali"

    function sync(): string {
      root.sync("ipc")
      return root.cli ? "syncing" : "plugin directory unknown"
    }
  }

  Component.onCompleted: preflight.running = true
}
