#!/usr/bin/env bash
# winlike-install.sh
#
# Turns a fresh Linux Mint 22 "Xfce" install into a lightweight, Windows 11-styled
# desktop tuned for an AMD Athlon II / 4 GB RAM machine:
#   - Firefox (+ uBlock Origin) for browsing
#   - LibreOffice with Calibri/Cambria-compatible fonts for documents
#   - Java 8 for Minecraft 1.7.10
#   - zram compressed swap, earlyoom, a "game mode" compositor toggle
#   - Fluent GTK theme + Win11-style icons, bottom taskbar, light acrylic look
#
# HOW TO RUN:
#   1. Log out of the desktop, press Ctrl+Alt+F3, log in as your normal user.
#   2. sudo bash winlike-install.sh
#   3. sudo reboot
# (Running from a text console stops the live desktop from overwriting the
#  settings this script writes.)
#
# This script uses no Microsoft logos, fonts or wallpapers. The look is built
# from open-source Fluent-style themes and Inter (a Segoe-like open font).

set -uo pipefail

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m!! %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31mxx %s\033[0m\n' "$*" >&2; exit 1; }

THEME="Mint-Y"
ICONS="Papirus"

# ISO-build mode: set WINLIKE_CHROOT=1 when running inside the chroot of a Mint
# ISO being remastered (see build-iso.sh). In that mode there is no logged-in
# user, services cannot be started, and the kernel must NOT be upgraded (the ISO's
# kernel files would no longer match its modules). Config goes to /etc/skel only.
CHROOT_MODE="${WINLIKE_CHROOT:-0}"
NOW="--now"
[[ "$CHROOT_MODE" == "1" ]] && NOW=""

# ---------------------------------------------------------------- packages ---
install_packages() {
  log "Updating package lists and installing software (this takes a while)"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update || warn "apt-get update failed - check your internet connection"
  if [[ "$CHROOT_MODE" != "1" ]]; then
    apt-get -y upgrade || warn "upgrade reported errors"
  fi

  local pkgs=(
    git curl unzip imagemagick sassc libnotify-bin
    firefox
    libreoffice-writer libreoffice-calc libreoffice-impress libreoffice-gtk3
    fonts-inter fonts-crosextra-carlito fonts-crosextra-caladea
    openjdk-8-jre mesa-utils
    zram-tools earlyoom
    papirus-icon-theme
    xfce4-whiskermenu-plugin xfce4-pulseaudio-plugin
  )
  local p
  for p in "${pkgs[@]}"; do
    apt-get -y install "$p" || warn "could not install $p (skipping)"
  done
}

# ------------------------------------------------------------------ themes ---
install_themes() {
  log "Installing Fluent theme and Win11-style icons"
  local w; w=$(mktemp -d)

  if git clone --depth=1 https://github.com/vinceliuice/Fluent-gtk-theme.git "$w/gtk"; then
    (cd "$w/gtk" && ./install.sh -d /usr/share/themes --tweaks round) \
      || warn "Fluent theme installer reported an error"
  else
    warn "Could not download the Fluent theme; falling back to Mint-Y"
  fi

  if git clone --depth=1 https://github.com/yeyushengfan258/Win11-icon-theme.git "$w/icons"; then
    (cd "$w/icons" && ./install.sh -d /usr/share/icons) \
      || warn "Win11 icon installer reported an error"
  else
    warn "Could not download Win11 icons; falling back to Papirus"
  fi
  rm -rf "$w"
  gtk-update-icon-cache -f /usr/share/icons/* >/dev/null 2>&1 || true
}

pick_theme() {
  local t
  t=$(ls /usr/share/themes 2>/dev/null | grep -E '^Fluent.*round.*Light$' | head -n1)
  [[ -z "$t" ]] && t=$(ls /usr/share/themes 2>/dev/null | grep -E '^Fluent.*Light$' | head -n1)
  [[ -n "$t" ]] && THEME="$t"

  local i
  i=$(ls /usr/share/icons 2>/dev/null | grep -i -E '^win11$' | head -n1)
  [[ -z "$i" ]] && i=$(ls /usr/share/icons 2>/dev/null | grep -i '^win11' | head -n1)
  [[ -n "$i" ]] && ICONS="$i"
  log "Using GTK/window theme: $THEME   icons: $ICONS"
}

# --------------------------------------------------------------- wallpaper ---
make_wallpaper() {
  log "Generating a blue 'bloom' style wallpaper"
  install -d /usr/share/backgrounds/winlike
  # Drawn small and blurred, then scaled up: fast even on an old CPU.
  convert -size 480x270 xc:'#06205f' \
    -fill '#1f5fe0' -draw 'ellipse 240,135,175,90,0,360' -blur 0x28 \
    -fill '#4fa3ff' -draw 'ellipse 260,125,80,45,0,360' -blur 0x22 \
    -fill '#bfe3ff' -draw 'ellipse 270,120,30,18,0,360' -blur 0x14 \
    -resize 1920x1080! -quality 92 /usr/share/backgrounds/winlike/bloom.jpg \
    || warn "Wallpaper generation failed (set any wallpaper you like instead)"
}

# ------------------------------------------------------------------ tuning ---
tune_system() {
  log "Memory and performance tuning for 4 GB RAM"

  cat >/etc/default/zramswap <<'EOF'
ALGO=lz4
PERCENT=50
PRIORITY=100
EOF

  cat >/etc/sysctl.d/99-winlike.conf <<'EOF'
vm.swappiness=100
vm.page-cluster=0
vm.vfs_cache_pressure=75
EOF
  sysctl --system >/dev/null 2>&1 || true

  systemctl enable $NOW zramswap.service 2>/dev/null || warn "could not enable zramswap"
  systemctl enable $NOW earlyoom.service 2>/dev/null || warn "could not enable earlyoom"
  systemctl disable $NOW ModemManager.service 2>/dev/null || true

  # Game mode: switch the window compositor off/on (helps fps in windowed Minecraft)
  cat >/usr/local/bin/gamemode-toggle <<'EOF'
#!/bin/sh
cur=$(xfconf-query -c xfwm4 -p /general/use_compositing)
if [ "$cur" = "true" ]; then
  xfconf-query -c xfwm4 -p /general/use_compositing -s false
  notify-send "Game mode ON" "Compositor off - more fps"
else
  xfconf-query -c xfwm4 -p /general/use_compositing -s true
  notify-send "Game mode OFF" "Compositor on - nicer look"
fi
EOF
  chmod 755 /usr/local/bin/gamemode-toggle

  # First-login helper: sets the wallpaper once (needs a running session).
  cat >/usr/local/bin/winlike-firstrun <<'EOF'
#!/bin/sh
sleep 4
img=/usr/share/backgrounds/winlike/bloom.jpg
[ -f "$img" ] || exit 0
props=$(xfconf-query -c xfce4-desktop -l 2>/dev/null | grep 'last-image$')
if [ -z "$props" ]; then
  props="/backdrop/screen0/monitor0/workspace0/last-image"
fi
for p in $props; do
  xfconf-query -c xfce4-desktop -p "$p" -n -t string -s "$img" 2>/dev/null \
    || xfconf-query -c xfce4-desktop -p "$p" -s "$img"
done
rm -f "$HOME/.config/autostart/winlike-firstrun.desktop"
EOF
  chmod 755 /usr/local/bin/winlike-firstrun
}

setup_firefox() {
  log "Firefox policies (uBlock Origin, no telemetry)"
  install -d /etc/firefox/policies
  cat >/etc/firefox/policies/policies.json <<'EOF'
{
  "policies": {
    "DisableTelemetry": true,
    "DontCheckDefaultBrowser": true,
    "OverrideFirstRunPage": "",
    "ExtensionSettings": {
      "uBlock0@raymondhill.net": {
        "installation_mode": "normal_installed",
        "install_url": "https://addons.mozilla.org/firefox/downloads/latest/ublock-origin/latest.xpi"
      }
    }
  }
}
EOF
}

# ------------------------------------------------------ per-user desktop cfg ---
# write_user_config <home> <owner-or-empty>
write_user_config() {
  local home="$1" owner="${2:-}"
  local xf="$home/.config/xfce4/xfconf/xfce-perchannel-xml"
  local pn="$home/.config/xfce4/panel"
  local au="$home/.config/autostart"

  install -d "$xf" "$pn" "$au"

  # one-time backup of whatever was there (real users only, not /etc/skel)
  if [[ -n "$owner" && -d "$home/.config/xfce4" && ! -e "$home/.config/xfce4.pre-winlike" ]]; then
    cp -a "$home/.config/xfce4" "$home/.config/xfce4.pre-winlike"
  fi

  rm -rf "$pn"/launcher-* "$pn"/whiskermenu-*.rc

  # --- look & feel ---------------------------------------------------------
  cat >"$xf/xsettings.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xsettings" version="1.0">
  <property name="Net" type="empty">
    <property name="ThemeName" type="string" value="$THEME"/>
    <property name="IconThemeName" type="string" value="$ICONS"/>
  </property>
  <property name="Gtk" type="empty">
    <property name="FontName" type="string" value="Inter 10"/>
    <property name="MonospaceFontName" type="string" value="Monospace 10"/>
  </property>
  <property name="Xft" type="empty">
    <property name="Antialiasing" type="int" value="1"/>
    <property name="HintStyle" type="string" value="hintslight"/>
    <property name="RGBA" type="string" value="rgb"/>
  </property>
</channel>
EOF

  cat >"$xf/xfwm4.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfwm4" version="1.0">
  <property name="general" type="empty">
    <property name="theme" type="string" value="$THEME"/>
    <property name="title_font" type="string" value="Inter Semi-Bold 10"/>
    <property name="title_alignment" type="string" value="left"/>
    <property name="button_layout" type="string" value="O|HMC"/>
    <property name="use_compositing" type="bool" value="true"/>
    <property name="unredirect_overlays" type="bool" value="true"/>
    <property name="show_dock_shadow" type="bool" value="false"/>
    <property name="show_popup_shadow" type="bool" value="false"/>
    <property name="show_frame_shadow" type="bool" value="true"/>
    <property name="vblank_mode" type="string" value="auto"/>
  </property>
</channel>
EOF

  # --- taskbar: launchers are only added if the app is installed -------------
  local next=3 launcher_xml="" idlist="" d
  for d in firefox thunar libreoffice-writer libreoffice-calc; do
    [[ -f "/usr/share/applications/$d.desktop" ]] || continue
    install -d "$pn/launcher-$next"
    cp "/usr/share/applications/$d.desktop" "$pn/launcher-$next/$d.desktop"
    launcher_xml+="    <property name=\"plugin-$next\" type=\"string\" value=\"launcher\">
      <property name=\"items\" type=\"array\">
        <value type=\"string\" value=\"$d.desktop\"/>
      </property>
    </property>
"
    idlist+="        <value type=\"int\" value=\"$next\"/>
"
    next=$((next + 1))
  done

  local tl=$next sep2=$((next + 1)) tray=$((next + 2)) vol=$((next + 3)) clk=$((next + 4)) sd=$((next + 5))

  cat >"$xf/xfce4-panel.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfce4-panel" version="1.0">
  <property name="configver" type="int" value="2"/>
  <property name="panels" type="array">
    <value type="int" value="1"/>
    <property name="dark-mode" type="bool" value="false"/>
    <property name="panel-1" type="empty">
      <property name="position" type="string" value="p=10;x=0;y=0"/>
      <property name="length" type="uint" value="100"/>
      <property name="position-locked" type="bool" value="true"/>
      <property name="size" type="uint" value="48"/>
      <property name="icon-size" type="uint" value="28"/>
      <property name="nrows" type="uint" value="1"/>
      <property name="background-style" type="uint" value="1"/>
      <property name="background-rgba" type="array">
        <value type="double" value="0.94"/>
        <value type="double" value="0.95"/>
        <value type="double" value="0.97"/>
        <value type="double" value="0.92"/>
      </property>
      <property name="plugin-ids" type="array">
        <value type="int" value="1"/>
        <value type="int" value="2"/>
${idlist}        <value type="int" value="$tl"/>
        <value type="int" value="$sep2"/>
        <value type="int" value="$tray"/>
        <value type="int" value="$vol"/>
        <value type="int" value="$clk"/>
        <value type="int" value="$sd"/>
      </property>
    </property>
  </property>
  <property name="plugins" type="empty">
    <property name="plugin-1" type="string" value="separator">
      <property name="expand" type="bool" value="true"/>
      <property name="style" type="uint" value="0"/>
    </property>
    <property name="plugin-2" type="string" value="whiskermenu"/>
${launcher_xml}    <property name="plugin-$tl" type="string" value="tasklist">
      <property name="show-labels" type="bool" value="false"/>
      <property name="flat-buttons" type="bool" value="true"/>
      <property name="show-handle" type="bool" value="false"/>
      <property name="grouping" type="uint" value="1"/>
    </property>
    <property name="plugin-$sep2" type="string" value="separator">
      <property name="expand" type="bool" value="true"/>
      <property name="style" type="uint" value="0"/>
    </property>
    <property name="plugin-$tray" type="string" value="systray">
      <property name="show-frame" type="bool" value="false"/>
      <property name="square-icons" type="bool" value="true"/>
    </property>
    <property name="plugin-$vol" type="string" value="pulseaudio"/>
    <property name="plugin-$clk" type="string" value="clock">
      <property name="mode" type="uint" value="2"/>
      <property name="digital-layout" type="uint" value="3"/>
      <property name="digital-time-format" type="string" value="%H:%M"/>
      <property name="digital-date-format" type="string" value="%d/%m/%Y"/>
    </property>
    <property name="plugin-$sd" type="string" value="showdesktop"/>
  </property>
</channel>
EOF

  # --- start menu ---------------------------------------------------------
  cat >"$pn/whiskermenu-2.rc" <<'EOF'
button-icon=start-here
show-button-title=false
launcher-show-description=false
display-recent=true
menu-width=520
menu-height=640
EOF

  # --- one-time wallpaper helper at first login --------------------------------
  cat >"$au/winlike-firstrun.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Winlike first run
Exec=/usr/local/bin/winlike-firstrun
Terminal=false
X-GNOME-Autostart-enabled=true
EOF

  if [[ -n "$owner" ]]; then
    chown -R "$owner:" "$home/.config/xfce4" "$home/.config/autostart" \
      "$home/.config/xfce4.pre-winlike" 2>/dev/null || true
  fi
}

# ------------------------------------------------------------------- main ---
main() {
  [[ $EUID -eq 0 ]] || die "Run with sudo:  sudo bash $0"

  if [[ "$CHROOT_MODE" == "1" ]]; then
    log "ISO build mode: configuring /etc/skel only"
    install_packages
    install_themes
    pick_theme
    make_wallpaper
    tune_system
    setup_firefox
    write_user_config /etc/skel ""
    log "ISO build mode finished"
    return 0
  fi

  local user="${SUDO_USER:-}"
  [[ -n "$user" && "$user" != root ]] || die "Run this with sudo from your normal user account, not as root."
  local home; home=$(getent passwd "$user" | cut -d: -f6)
  [[ -d "$home" ]] || die "Cannot find home directory for $user"

  [[ "$(uname -m)" == x86_64 ]] || warn "This is not a 64-bit system; Java/Firefox choices assume x86_64."
  grep -qiE 'mint|ubuntu' /etc/os-release || warn "Written for Linux Mint 22 / Ubuntu 24.04 based systems; others may need edits."

  if pgrep -u "$user" -x xfce4-session >/dev/null 2>&1; then
    warn "Your Xfce desktop is still running. For best results log out and run this from Ctrl+Alt+F3."
    read -r -p "Continue anyway? [y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]] || exit 1
  fi

  install_packages
  install_themes
  pick_theme
  make_wallpaper
  tune_system
  setup_firefox

  log "Writing desktop configuration for $user and for new users"
  write_user_config "$home" "$user"
  write_user_config /etc/skel ""

  log "Done. Reboot now:  sudo reboot"
  echo "Then follow README.md for the Minecraft 1.7.10 setup."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
