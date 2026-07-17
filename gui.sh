#!/bin/bash
set -euo pipefail

pkgs=(
  noto-fonts
  noto-fonts-cjk
  noto-fonts-emoji
  ttf-jetbrains-mono-nerd
  otf-font-awesome
  sddm
  qt6-declarative
  qt6-5compat
  qt6-svg
  qt6-multimedia
  qt6-multimedia-ffmpeg
  polkit-gnome # TODO: написать свое
  libappindicator
  xdg-desktop-portal-gtk
  xdg-desktop-portal-hyprland
  xdg-terminal-exec
  wl-clip-persist
  uwsm
  libnewt
  runapp
  hyprland
  qt5-wayland
  qt6-wayland
  hyprpicker
  hyprshot
  awww
  waybar
  swaync
  walker
  nautilus
  gvfs-mtp
  mesa-utils
  nautilus-admin-gtk4
  nautilus-gnome-disks
  nautilus-open-any-terminal
  actions-for-nautilus-git
  loupe
  sushi
  file-roller
  gparted
  xorg-xhost
  nwg-look
  dconf-editor
  papirus-icon-theme
  papirus-folders-git
  kitty
  openbsd-netcat
  elephant
  elephant-menus
  elephant-desktopapplications
  elephant-archlinuxpkgs
  elephant-clipboard
  elephant-providerlist
  elephant-websearch
  elephant-wireplumber
  nvidia-settings
  speech-dispatcher
  telegram-desktop
  meld
  libreoffice-fresh-ru
)

read -rp "Установить solaar? [Y/n]: " SET_SOL
[[ ! "$SET_SOL" =~ ^[Nn]$ ]] && pkgs+=(solaar)

paru -S --needed --noconfirm --failfast "${pkgs[@]}"

if [[ ! -f ~/.config/user-dirs.locale || $(<~/.config/user-dirs.locale) != C ]]; then
  LC_ALL=C.UTF-8 xdg-user-dirs-update --force
fi

curl -fsSL https://github.com/zen-browser/updates-server/raw/refs/heads/main/install.sh | bash

sudo systemctl enable sddm
systemctl enable --user waybar swaync

(
  cd ~/.dotfiles/
  rm -rf ~/.config/{electron-flags.conf,hypr,kitty,uwsm,walker,elephant,waybar,xdg-terminals.list}
  stow -vS electron GTK hypr kitty nautilus-actions uwsm walker waybar xdg-terminal-exec
  if [[ ! "$SET_SOL" =~ ^[Nn]$ ]]; then
    rm -rf ~/config/solaar
    stow -vS solaar
  fi
)

rm -rf ~/.config/go/
go telemetry off

dconf load / <~/.config/nwg-look/dconf.ini
nwg-look -x
papirus-folders -C teal --theme Papirus-Dark

(
  cd && git clone https://github.com/Darkkal44/qylock.git .qylock
  cd .qylock
  chmod +x sddm.sh && ./sddm.sh
)
