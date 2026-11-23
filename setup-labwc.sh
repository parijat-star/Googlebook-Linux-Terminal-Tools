#!/usr/bin/env bash
#
# Converts a fresh Android Terminal (Ferrochrome) Debian 13 (Trixie) VM from the
# default Weston setup to a minimal labwc + Waybar + Wofi/Fuzzel + Foot desktop
# with persistent Xwayland (X11) support and automatic DPI/resolution scaling.
#
# - Overrides weston.service / weston.socket in ~/.config/systemd/user so the
#   setup survives future cidata.iso updates (which overwrite /etc and /usr/local).
# - Dynamically detects Virtio-GPU Venus (venus_enabled), Gfxstream
#   (gfxstream_enabled), or software Lavapipe on every boot via /proc/cmdline.
# - Automatically detects Full vs. Half display resolution (and live changes in
#   Terminal Settings / window resizes) via DRM hotplug + wlr-randr physical DPI,
#   adjusting Wayland output scale to match Android's 160-dpi baseline.
#
# Usage:
#   ./setup-labwc.sh                  # Install and switch to labwc + waybar + wofi
#   ./setup-labwc.sh --restore-weston # Revert back to the stock Weston setup

set -euo pipefail

readonly PROFILE_ENV_FILE="/etc/profile.d/zz-labwc-wayland.sh"

# Core packages only (installed with --no-install-recommends to keep the VM slim).
readonly CORE_PACKAGES=(
  adwaita-icon-theme
  dbus-user-session
  fonts-dejavu-core
  foot
  fuzzel
  hicolor-icon-theme
  labwc
  libnotify-bin
  librsvg2-common
  mako-notifier
  python3
  socat
  swaybg
  udev
  waybar
  wlr-randr
  wlrctl
  wl-clipboard
  wofi
  xauth
  xfonts-base
  xwayland
)

log() {
  printf '\033[1;32m==>\033[0m %s\n' "$*"
}

warn() {
  printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2
}

die() {
  printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: setup-labwc.sh [OPTION]

Options:
  (no args)          Install core packages and switch display session to labwc + waybar + wofi
  --restore-weston   Remove user systemd overrides and switch back to stock Weston
  -h, --help         Show this help message
EOF
}

ensure_regular_user() {
  if [[ "${EUID}" -eq 0 ]]; then
    die "Run this script as your regular VM user (e.g. 'droid'), not with sudo. It calls sudo internally when needed."
  fi
  export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
  if [[ ! -d "${XDG_RUNTIME_DIR}" ]]; then
    die "XDG_RUNTIME_DIR (${XDG_RUNTIME_DIR}) does not exist; systemd user manager is not running."
  fi
}

restore_weston() {
  log "Stopping labwc session (user weston.service override)..."
  systemctl --user stop weston.service 2>/dev/null || true
  systemctl --user disable weston.service 2>/dev/null || true

  log "Removing ~/.config/systemd/user overrides and shell profile hook..."
  rm -f "${HOME}/.config/systemd/user/weston.service" \
        "${HOME}/.config/systemd/user/weston.socket"
  sudo rm -f "${PROFILE_ENV_FILE}"

  systemctl --user daemon-reload
  systemctl --user unset-environment WAYLAND_DISPLAY DISPLAY XDG_CURRENT_DESKTOP XCURSOR_THEME XCURSOR_SIZE 2>/dev/null || true

  if ! grep -q -w "wayland_bridge" /proc/cmdline; then
    log "Starting stock Weston service..."
    systemctl --user start weston.socket weston.service
  fi

  log "Stock Weston setup restored."
}

install_packages() {
  log "Updating apt package lists and installing core Wayland + Xwayland desktop stack..."
  sudo apt-get update
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    "${CORE_PACKAGES[@]}"

  # Register foot as x-terminal-emulator if not already registered so standard launchers find it.
  if [[ -x /usr/bin/foot ]] && ! update-alternatives --query x-terminal-emulator 2>/dev/null | grep -q '/usr/bin/foot'; then
    sudo update-alternatives --install /usr/bin/x-terminal-emulator x-terminal-emulator /usr/bin/foot 50 || true
  fi
}

write_helper_scripts() {
  log "Writing launcher, auto-scale, and host-notification helpers to ~/.local/bin..."
  mkdir -p "${HOME}/.local/bin"

  # 1. Compositor wrapper: clears DISPLAY/WAYLAND_DISPLAY/XDG_SESSION_ID for the
  #    labwc process itself so wlroots opens KMS/DRM + libinput (labwc then spawns
  #    Xwayland on :0 and exports DISPLAY=:0 to child apps and systemd --user).
  cat <<'EOF' > "${HOME}/.local/bin/labwc-start"
#!/usr/bin/env bash
set -euo pipefail

# Ensure full standard PATH (including /usr/games for Debian X11 packages) is
# inherited by labwc, waybar, and GUI app launchers under systemd --user.
export PATH="/usr/local/bin:/usr/bin:/bin:/usr/local/games:/usr/games:${PATH:-}"

# Clear outer DISPLAY/WAYLAND_DISPLAY for labwc's own startup so wlroots uses KMS/DRM
# rather than trying to nest inside an existing X11/Wayland server.
unset DISPLAY WAYLAND_DISPLAY WAYLAND_SOCKET XDG_SESSION_ID

# Remove stale :0 X11 lock if no Xwayland/Xorg process is alive so labwc's Xwayland gets :0.
if ! pgrep -x Xwayland >/dev/null 2>&1 && [[ -f /tmp/.X0-lock ]]; then
  rm -f /tmp/.X0-lock /tmp/.X11-unix/X0 2>/dev/null || true
fi

export WLR_BACKENDS=drm,libinput
export XDG_CURRENT_DESKTOP=wlroots
export XDG_SESSION_TYPE=wayland
export XCURSOR_THEME=Adwaita
export XCURSOR_SIZE=24

find_vulkan_icd() {
  local base="$1"
  local arch
  arch="$(uname -m)"
  local candidate
  for candidate in \
    "/usr/local/share/vulkan/icd.d/${base}.${arch}.json" \
    "/usr/local/share/vulkan/icd.d/${base}.json" \
    "/usr/share/vulkan/icd.d/${base}.${arch}.json" \
    "/usr/share/vulkan/icd.d/${base}.json"; do
    if [[ -f "${candidate}" ]]; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done
  return 1
}

if grep -q -w "venus_enabled" /proc/cmdline; then
  # Virtio-GPU Venus (26Q3+ desktop release GPU acceleration; see enable_venus)
  unset LIBGL_ALWAYS_SOFTWARE
  export MESA_LOADER_DRIVER_OVERRIDE=zink
  export ZINK_DEBUG=norp
  if icd_path="$(find_vulkan_icd virtio_icd)"; then
    export VK_ICD_FILENAMES="${icd_path}"
    export VK_DRIVER_FILES="${icd_path}"
  fi
  echo "labwc-start: detected Virtio-GPU Venus (ICD=${VK_ICD_FILENAMES:-none})"
elif grep -q -w "gfxstream_enabled" /proc/cmdline; then
  # Virtio-GPU Gfxstream (disable Xwayland Glamor as gfxstream lacks native GBM)
  unset LIBGL_ALWAYS_SOFTWARE
  export MESA_LOADER_DRIVER_OVERRIDE=zink
  export MESA_VK_WSI_DEBUG=sw
  export XWAYLAND_NO_GLAMOR=1
  if icd_path="$(find_vulkan_icd gfxstream_vk_icd)"; then
    export VK_ICD_FILENAMES="${icd_path}"
    export VK_DRIVER_FILES="${icd_path}"
  fi
  echo "labwc-start: detected Virtio-GPU Gfxstream (ICD=${VK_ICD_FILENAMES:-none})"
else
  # Software rendering (Lavapipe for client apps, fast pixman 2D blitting for labwc)
  export WLR_RENDERER=pixman
  export MESA_LOADER_DRIVER_OVERRIDE=zink
  export LIBGL_ALWAYS_SOFTWARE=1
  if icd_path="$(find_vulkan_icd lvp_icd)"; then
    export VK_ICD_FILENAMES="${icd_path}"
    export VK_DRIVER_FILES="${icd_path}"
  fi
  echo "labwc-start: detected software rendering / Lavapipe (ICD=${VK_ICD_FILENAMES:-none})"
fi

# Respect per-device RRO forcing software compositor rendering if present.
if grep -q -w "weston_force_pixman" /proc/cmdline; then
  export WLR_RENDERER=pixman
fi

# Composite cursors directly into the primary framebuffer rather than crosvm's
# separate virtio-gpu cursor SurfaceView: TerminalApp's DisplayProvider.CursorHandler
# positions the hardware cursor surface in raw guest pixels without scaling by
# 1/resolution.scale in Half-resolution mode. Software cursor compositing keeps
# move/resize cursor shapes, hotspots, and HiDPI scaling exact in all modes.
export WLR_NO_HARDWARE_CURSORS=1

exec /usr/bin/labwc
EOF
  chmod +x "${HOME}/.local/bin/labwc-start"

  # 2. App launcher wrapper: toggles GTK3 wofi Start menu with guaranteed DISPLAY
  #    and PATH so both Wayland and X11 (.desktop) apps launch on single click/touch.
  cat <<'EOF' > "${HOME}/.local/bin/app-launcher"
#!/usr/bin/env bash
set -euo pipefail

if pkill -x wofi 2>/dev/null; then
  exit 0
fi

export PATH="/usr/local/bin:/usr/bin:/bin:/usr/local/games:/usr/games:${PATH:-}"
export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"

if [[ -z "${DISPLAY:-}" ]]; then
  for sock in /tmp/.X11-unix/X*; do
    if [[ -S "${sock}" ]]; then
      export DISPLAY=":${sock##*/X}"
      break
    fi
  done
  export DISPLAY="${DISPLAY:-:0}"
fi

exec wofi --show drun
EOF
  chmod +x "${HOME}/.local/bin/app-launcher"

  # 3. Dynamic DPI / resolution auto-scaler:
  #    TerminalApp's DisplayProvider passes `dpi = hostDensityDpi * resolution.scale`
  #    (1.0 for Full resolution, 0.5 for Half resolution) to crosvm, which exposes
  #    it via the Wayland output's pixel mode and physical_size (mm).
  #    This daemon listens passively to DRM hotplug events (`udevadm monitor`) and
  #    adjusts `wlr-randr --scale` so Half-res stays 1.0x while Full-res scales
  #    proportionally to Android's 160-dpi baseline (e.g. 1.75x on 280dpi, 2.0x on 320dpi).
  cat <<'EOF' > "${HOME}/.local/bin/labwc-autoscale"
#!/usr/bin/env python3
import json
import os
import select
import subprocess
import sys
import time

CONF_PATH = os.path.expanduser("~/.config/labwc/autoscale.conf")


def load_config():
    cfg = {"base_dpi": 160.0, "min_hidpi": 190.0, "fixed_scale": None}
    if os.path.isfile(CONF_PATH):
        with open(CONF_PATH, "r", encoding="utf-8") as f:
            for raw in f:
                line = raw.split("#", 1)[0].strip()
                if "=" not in line:
                    continue
                k, v = [x.strip() for x in line.split("=", 1)]
                if k == "BASE_DPI" and v:
                    cfg["base_dpi"] = float(v)
                elif k == "MIN_HIDPI" and v:
                    cfg["min_hidpi"] = float(v)
                elif k == "FIXED_SCALE" and v:
                    cfg["fixed_scale"] = float(v)
    return cfg


def compute_scale(px_width, phys_mm_width, cfg):
    if cfg["fixed_scale"] is not None:
        return max(1.0, min(3.0, cfg["fixed_scale"]))
    if px_width <= 0 or phys_mm_width <= 0:
        return 1.0
    dpi = (px_width * 25.4) / phys_mm_width
    # Keep Half-resolution (typically 120-180 dpi) and standard 1080p (160 dpi) at crisp 1.0x.
    if dpi < cfg["min_hidpi"]:
        return 1.0
    # Snap Full-resolution HiDPI (e.g. 240->1.5, 280->1.75, 320->2.0, 360->2.25) to 0.25 steps.
    snapped = round((dpi / cfg["base_dpi"]) * 4.0) / 4.0
    return max(1.0, min(3.0, snapped))


def apply_scales():
    cfg = load_config()
    res = subprocess.run(
        ["wlr-randr", "--json"],
        capture_output=True,
        text=True,
        check=False,
    )
    if res.returncode != 0:
        return False
    try:
        heads = json.loads(res.stdout)
    except json.JSONDecodeError:
        return True

    for head in heads:
        if not head.get("enabled"):
            continue
        name = head.get("name")
        phys_w = (head.get("physical_size") or {}).get("width") or 0
        cur_scale = float(head.get("scale") or 1.0)
        px_w = 0
        for m in head.get("modes") or []:
            if m.get("current"):
                px_w = int(m.get("width") or 0)
                break
        if not name or px_w <= 0:
            continue
        target = compute_scale(px_w, phys_w, cfg)
        if abs(cur_scale - target) > 0.05:
            dpi = (px_w * 25.4 / phys_w) if phys_w > 0 else 0.0
            print(
                f"labwc-autoscale: {name} {px_w}px ({phys_w}mm, {dpi:.0f} dpi) "
                f"scale {cur_scale:.2f} -> {target:.2f}",
                flush=True,
            )
            subprocess.run(
                ["wlr-randr", "--output", name, "--scale", f"{target:.2f}"],
                check=False,
            )
    return True


def main():
    for _ in range(20):
        if apply_scales():
            break
        time.sleep(0.25)

    mon = subprocess.Popen(
        ["udevadm", "monitor", "--udev", "--subsystem-match=drm"],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
    )
    if mon.stdout is None:
        return

    try:
        while True:
            rlist, _, _ = select.select([mon.stdout], [], [])
            if not rlist:
                continue
            line = mon.stdout.readline()
            if not line:
                break
            # Drain burst of add+remove DRM hotplug lines during DisplayProvider resize.
            time.sleep(0.15)
            while select.select([mon.stdout], [], [], 0)[0]:
                if not mon.stdout.readline():
                    break
            if not apply_scales():
                break
            # Follow-up pass in case labwc enabled the new wl_output slightly after udev.
            time.sleep(0.35)
            if not apply_scales():
                break
    finally:
        mon.terminate()


if __name__ == "__main__":
    sys.exit(main())
EOF
  chmod +x "${HOME}/.local/bin/labwc-autoscale"

  # 4. Event-driven replacement for libweston_window_notify.so so TerminalApp's
  #    active-display indicator badge continues to work with zero CPU polling.
  cat <<'EOF' > "${HOME}/.local/bin/labwc-window-notify"
#!/usr/bin/env bash
set -uo pipefail

readonly SOCK="/run/active_window.sock"

send_state() {
  if [[ -S "${SOCK}" ]]; then
    printf '%s' "$1" | socat -u - "UNIX-SENDTO:${SOCK}" 2>/dev/null || true
  fi
}

send_state 0
while wlrctl toplevel waitfor 2>/dev/null; do
  send_state 1
  wlrctl toplevel wait 2>/dev/null || true
  if ! wlrctl toplevel find 2>/dev/null; then
    send_state 0
  fi
done
EOF
  chmod +x "${HOME}/.local/bin/labwc-window-notify"
}

write_desktop_configs() {
  log "Writing labwc, cursor theme, autoscale, waybar, wofi, fuzzel, foot, and mako configs..."
  mkdir -p "${HOME}/.config/labwc" \
           "${HOME}/.config/gtk-3.0" \
           "${HOME}/.config/waybar" \
           "${HOME}/.config/wofi" \
           "${HOME}/.config/fuzzel" \
           "${HOME}/.config/foot" \
           "${HOME}/.config/mako" \
           "${HOME}/.icons/default" \
           "${HOME}/.local/share/icons/default" \
           "${HOME}/.local/share/applications"

  # Ensure Adwaita cursors (grab/grabbing, 8-way *-resize, etc.) are picked up
  # consistently by labwc, GTK3 Wayland apps, and X11/Xwayland apps even under
  # --no-install-recommends (which skips system-wide x-cursor-theme alternatives).
  for cursor_index in \
    "${HOME}/.icons/default/index.theme" \
    "${HOME}/.local/share/icons/default/index.theme"; do
    cat <<'EOF' > "${cursor_index}"
[Icon Theme]
Name=Default
Comment=Default Cursor Theme
Inherits=Adwaita
EOF
  done

  cat <<'EOF' > "${HOME}/.config/gtk-3.0/settings.ini"
[Settings]
gtk-icon-theme-name=Adwaita
gtk-cursor-theme-name=Adwaita
gtk-cursor-theme-size=24
EOF

  # Hide Foot Server / Foot Client clutter from the application menu so only Foot appears.
  for hidden_desktop in foot-server.desktop footclient.desktop; do
    if [[ -f "/usr/share/applications/${hidden_desktop}" ]]; then
      cp "/usr/share/applications/${hidden_desktop}" "${HOME}/.local/share/applications/${hidden_desktop}"
      if ! grep -q '^NoDisplay=' "${HOME}/.local/share/applications/${hidden_desktop}"; then
        printf '\nNoDisplay=true\n' >> "${HOME}/.local/share/applications/${hidden_desktop}"
      fi
    fi
  done

  # Optional user-editable scaling config (preserve existing edits on re-run if present).
  if [[ ! -f "${HOME}/.config/labwc/autoscale.conf" ]]; then
    cat <<'EOF' > "${HOME}/.config/labwc/autoscale.conf"
# Automatic Wayland output scaling parameters (read live on resize / resolution switch).
# Lower BASE_DPI (e.g. 140) for slightly larger UI in Full-res; raise (e.g. 180) for smaller.
BASE_DPI=160
MIN_HIDPI=190
# Uncomment to force a fixed scale (e.g. FIXED_SCALE=1.75) regardless of resolution mode:
# FIXED_SCALE=
EOF
  fi

  # --- labwc: rc.xml (persistent Xwayland, clean 11pt fonts, crosvm tap-to-click) ---
  cat <<'EOF' > "${HOME}/.config/labwc/rc.xml"
<?xml version="1.0"?>
<labwc_config>
  <core>
    <gap>0</gap>
    <xwaylandPersistence>yes</xwaylandPersistence>
  </core>
  <resize>
    <minimumArea>10</minimumArea>
  </resize>
  <theme>
    <name>Adwaita</name>
    <font place="ActiveWindow">
      <name>DejaVu Sans</name>
      <size>11</size>
    </font>
    <font place="InactiveWindow">
      <name>DejaVu Sans</name>
      <size>11</size>
    </font>
    <font place="MenuItem">
      <name>DejaVu Sans</name>
      <size>11</size>
    </font>
    <titlebar>
      <layout>icon:iconify,max,close</layout>
      <showTitle>yes</showTitle>
    </titlebar>
  </theme>
  <libinput>
    <device category="default">
      <!-- crosvm's virtual trackpad has INPUT_PROP_BUTTONPAD; force enable tap-to-click -->
      <tap>yes</tap>
      <!-- Range: -1.0 (slowest) to 0.0 (default) to 1.0 (fastest). Reload live via: labwc -r -->
      <pointerSpeed>-0.5</pointerSpeed>
      <accelProfile>adaptive</accelProfile>
    </device>
  </libinput>
  <keyboard>
    <default />
    <keybind key="W-Return">
      <action name="Execute" command="foot" />
    </keybind>
    <keybind key="W-d">
      <action name="Execute" command="sh -c '$HOME/.local/bin/app-launcher'" />
    </keybind>
    <keybind key="W-space">
      <action name="Execute" command="sh -c '$HOME/.local/bin/app-launcher'" />
    </keybind>
  </keyboard>
</labwc_config>
EOF

  # --- labwc: themerc-override (compact, balanced titlebar & min/max/close buttons) ---
  cat <<'EOF' > "${HOME}/.config/labwc/themerc-override"
padding.height: 4
window.titlebar.padding.width: 6
window.titlebar.padding.height: 3
window.button.width: 26
window.button.height: 26
window.button.spacing: 3
border.width: 2
EOF

  # --- labwc: right-click desktop menu ---
  cat <<'EOF' > "${HOME}/.config/labwc/menu.xml"
<?xml version="1.0" encoding="UTF-8"?>
<openbox_menu>
  <menu id="root-menu" label="Desktop">
    <item label="Applications...">
      <action name="Execute" command="sh -c '$HOME/.local/bin/app-launcher'" />
    </item>
    <item label="Terminal (Foot)">
      <action name="Execute" command="foot" />
    </item>
    <separator />
    <item label="Reconfigure">
      <action name="Reconfigure" />
    </item>
  </menu>
</openbox_menu>
EOF

  # --- labwc: autostart (Xwayland DISPLAY sync + autoscale + bar + notifications) ---
  cat <<'EOF' > "${HOME}/.config/labwc/autostart"
export PATH="/usr/local/bin:/usr/bin:/bin:/usr/local/games:/usr/games:${PATH:-}"
if [ -z "${DISPLAY:-}" ]; then
  for _i in 1 2 3 4 5 6 7 8 9 10; do
    if [ -S /tmp/.X11-unix/X0 ]; then
      export DISPLAY=:0
      break
    fi
    sleep 0.1
  done
  export DISPLAY="${DISPLAY:-:0}"
fi
dbus-update-activation-environment --systemd WAYLAND_DISPLAY DISPLAY PATH XDG_CURRENT_DESKTOP XDG_SESSION_TYPE XCURSOR_THEME XCURSOR_SIZE >/dev/null 2>&1 || true
"$HOME/.local/bin/labwc-autoscale" >/dev/null 2>&1 &
swaybg -c '#1e222a' >/dev/null 2>&1 &
mako >/dev/null 2>&1 &
waybar >/dev/null 2>&1 &
"$HOME/.local/bin/labwc-window-notify" >/dev/null 2>&1 &
EOF
  chmod +x "${HOME}/.config/labwc/autostart"

  # --- waybar: compact 38px taskbar (auto-scales to crisp HiDPI in Full-res mode) ---
  cat <<'EOF' > "${HOME}/.config/waybar/config.jsonc"
{
  "layer": "top",
  "position": "bottom",
  "height": 38,
  "spacing": 4,
  "modules-left": ["custom/launcher", "custom/terminal", "wlr/taskbar"],
  "modules-right": ["tray", "cpu", "memory", "clock"],

  "custom/launcher": {
    "format": "☰ Apps",
    "on-click": "$HOME/.local/bin/app-launcher",
    "tooltip-format": "Open Application Menu (Super+Space)"
  },
  "custom/terminal": {
    "format": ">_",
    "on-click": "foot",
    "tooltip-format": "Open Foot Terminal (Super+Enter)"
  },
  "wlr/taskbar": {
    "format": "{icon} {title:.24}",
    "icon-theme": "Adwaita",
    "icon-size": 18,
    "tooltip-format": "{title}",
    "on-click": "minimize-raise",
    "on-click-middle": "close"
  },
  "tray": {
    "icon-size": 17,
    "spacing": 8
  },
  "cpu": {
    "interval": 5,
    "format": "CPU {usage}%"
  },
  "memory": {
    "interval": 5,
    "format": "MEM {percentage}%"
  },
  "clock": {
    "format": "{:%H:%M}",
    "tooltip-format": "{:%A, %Y-%m-%d}"
  }
}
EOF

  cat <<'EOF' > "${HOME}/.config/waybar/style.css"
* {
  font-family: "DejaVu Sans", sans-serif;
  font-size: 13px;
  border: none;
  border-radius: 0;
  min-height: 0;
}

window#waybar {
  background-color: #16191f;
  color: #dcdfe4;
  border-top: 1px solid #2c313c;
}

#custom-launcher {
  background-color: #2b5b84;
  color: #ffffff;
  font-weight: bold;
  padding: 0 10px;
  margin: 4px 2px 4px 6px;
  border-radius: 5px;
}

#custom-launcher:hover {
  background-color: #3670a0;
}

#custom-terminal {
  background-color: #252a34;
  color: #dcdfe4;
  font-family: "DejaVu Sans Mono", monospace;
  font-weight: bold;
  padding: 0 9px;
  margin: 4px 4px 4px 2px;
  border-radius: 5px;
}

#custom-terminal:hover {
  background-color: #323846;
}

#taskbar button {
  background-color: #21252e;
  color: #abb2bf;
  padding: 0 10px;
  margin: 4px 2px;
  border-radius: 5px;
}

#taskbar button:hover {
  background-color: #2c313c;
  color: #ffffff;
}

#taskbar button.active {
  background-color: #333a48;
  color: #ffffff;
  border-bottom: 2px solid #61afef;
}

#taskbar button.minimized {
  background-color: transparent;
  color: #6b7280;
}

#tray, #cpu, #memory, #clock {
  padding: 0 10px;
  margin: 4px 2px;
  background-color: #21252e;
  border-radius: 5px;
}

#clock {
  font-weight: bold;
  margin-right: 6px;
}
EOF

  # --- wofi: GTK3 Start Menu docked above "☰ Apps" (clean 13px font + single-click/touch) ---
  cat <<'EOF' > "${HOME}/.config/wofi/config"
show=drun
prompt=Search apps...
location=bottom_left
xoffset=6
yoffset=-6
width=300
height=340
allow_images=true
image_size=20
insensitive=true
single_click=true
no_actions=true
term=foot
EOF

  cat <<'EOF' > "${HOME}/.config/wofi/style.css"
window {
  font-family: "DejaVu Sans", sans-serif;
  font-size: 13px;
  background-color: #16191f;
  color: #dcdfe4;
  border: 1px solid #3e4452;
  border-radius: 8px;
}

#outer-box {
  margin: 6px;
}

#input {
  padding: 6px 10px;
  margin-bottom: 6px;
  background-color: #21252e;
  color: #ffffff;
  border: 1px solid #3e4452;
  border-radius: 5px;
}

#entry {
  padding: 6px 8px;
  border-radius: 5px;
}

#entry:selected {
  background-color: #2b5b84;
  color: #ffffff;
}

#text {
  margin-left: 8px;
}
EOF

  # --- fuzzel: disable physical-DPI font scaling (dpi-aware=no) if invoked manually ---
  cat <<'EOF' > "${HOME}/.config/fuzzel/fuzzel.ini"
[main]
dpi-aware=no
font=DejaVu Sans:size=11
icon-theme=Adwaita
terminal=foot -e
prompt="Launch: "
width=38
lines=10
horizontal-pad=14
vertical-pad=10
inner-pad=6

[colors]
background=16191fee
text=dcdfe4ff
match=61afefff
selection=2c313cff
selection-text=ffffffff
selection-match=61afefff
border=3e4452ff

[border]
width=1
radius=8
EOF

  # --- foot: disable physical-DPI font scaling (dpi-aware=no; respects Wayland output scale) ---
  cat <<'EOF' > "${HOME}/.config/foot/foot.ini"
[main]
dpi-aware=no
font=DejaVu Sans Mono:size=11
pad=6x6

[colors]
background=16191f
foreground=dcdfe4
EOF

  # --- mako: compact notifications ---
  cat <<'EOF' > "${HOME}/.config/mako/config"
font=DejaVu Sans 11
background-color=#16191fee
text-color=#dcdfe4
border-color=#3e4452
border-size=1
border-radius=6
default-timeout=5000
EOF
}

configure_systemd_and_profile() {
  log "Configuring ~/.config/systemd/user overrides (survives cidata.iso updates)..."
  mkdir -p "${HOME}/.config/systemd/user"

  # Stop stock Weston (and any manual foreground labwc) so /run/user/1000/wayland-0
  # and DRM master are freed cleanly.
  systemctl --user stop weston.service weston.socket 2>/dev/null || true
  pkill -x labwc 2>/dev/null || true

  # Mask weston.socket at the user level (higher precedence than /etc/systemd/user)
  # because weston.socket passes LISTEN_FDS, whereas labwc binds wayland-0 itself.
  ln -sfn /dev/null "${HOME}/.config/systemd/user/weston.socket"

  # Remove first in case weston.service was previously masked (symlinked to /dev/null).
  rm -f "${HOME}/.config/systemd/user/weston.service"

  # Shadow /etc/systemd/user/weston.service completely so stock calls to
  # `systemctl --user start weston` (from /usr/local/bin/enable_display) start labwc.
  cat <<'EOF' > "${HOME}/.config/systemd/user/weston.service"
[Unit]
Description=Labwc Wayland compositor (shadowing weston.service for Android Terminal)
ConditionKernelCommandLine=!wayland_bridge
Before=graphical-session.target
StartLimitIntervalSec=30
StartLimitBurst=10

[Service]
Type=simple
ExecStart=%h/.local/bin/labwc-start
Restart=on-failure
RestartSec=2
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=default.target
EOF

  # Export WAYLAND_DISPLAY and sync live Xwayland DISPLAY in interactive Terminal tabs.
  sudo tee "${PROFILE_ENV_FILE}" >/dev/null <<'EOF'
# Export WAYLAND_DISPLAY and active Xwayland DISPLAY when wayland_bridge is disabled.
if [ "${USER:-}" = "droid" ] && ! grep -q -w "wayland_bridge" /proc/cmdline; then
  export WAYLAND_DISPLAY=wayland-0
  export XDG_CURRENT_DESKTOP=wlroots
  export XDG_SESSION_TYPE=wayland
  export XCURSOR_THEME=Adwaita
  export XCURSOR_SIZE=24
  _labwc_disp="$(systemctl --user show-environment 2>/dev/null | sed -n 's/^DISPLAY=//p' | head -n 1)"
  export DISPLAY="${_labwc_disp:-:0}"
  unset _labwc_disp
fi
EOF
  sudo chmod 0644 "${PROFILE_ENV_FILE}"

  systemctl --user daemon-reload
  systemctl --user enable weston.service

  if grep -q -w "venus_enabled" /proc/cmdline; then
    log "Detected active guest GPU mode: Virtio-GPU Venus (venus_enabled)"
  elif grep -q -w "gfxstream_enabled" /proc/cmdline; then
    log "Detected active guest GPU mode: Virtio-GPU Gfxstream (gfxstream_enabled)"
  else
    log "Detected active guest GPU mode: Software / Lavapipe (will auto-switch if GPU is enabled in Terminal Settings)"
  fi

  if grep -q -w "wayland_bridge" /proc/cmdline; then
    warn "'wayland_bridge' is currently enabled in Terminal Settings; labwc will remain inactive until multi-window mode is turned off."
  else
    log "Starting labwc desktop session..."
    systemctl --user start weston.service
  fi
}

main() {
  case "${1:-}" in
    "")
      ensure_regular_user
      install_packages
      write_helper_scripts
      write_desktop_configs
      configure_systemd_and_profile
      log "Done! Open the Display view (monitor icon) in Terminal to use labwc + Waybar + Wofi."
      log "Auto-scaling is active (edit ~/.config/labwc/autoscale.conf to fine-tune BASE_DPI if desired)."
      log "Tip: In existing terminal tabs, run 'export WAYLAND_DISPLAY=wayland-0 DISPLAY=:0' (new tabs set both automatically)."
      log "To revert to stock Weston anytime, run: $0 --restore-weston"
      ;;
    --restore-weston)
      ensure_regular_user
      restore_weston
      ;;
    -h|--help)
      usage
      ;;
    *)
      usage >&2
      die "Unknown argument: $1"
      ;;
  esac
}

main "$@"