#!/bin/bash
set -euo pipefail

pkgs=(
  noto-fonts
  noto-fonts-cjk
  noto-fonts-emoji
  ttf-jetbrains-mono-nerd
  otf-font-awesome
  sddm
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
  nwg-look
  dconf-editor
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
)

read -rp "Установить мои .dotfiles и настроить stow? [Y/n]: " SET_SOL
[[ ! "$SET_SOL" =~ ^[Nn]$ ]] && pkgs+=(solaar)

if [[ ! -f ~/.config/user-dirs.locale || $(<~/.config/user-dirs.locale) != C ]]; then
  LC_ALL=C.UTF-8 xdg-user-dirs-update --force
fi

paru -S --needed --noconfirm --failfast "${pkgs[@]}"
curl -fsSL https://github.com/zen-browser/updates-server/raw/refs/heads/main/install.sh | bash

gsettings set com.github.stunkymonkey.nautilus-open-any-terminal terminal kitty

sudo systemctl enable sddm

(
  cd ~/.dotfiles/
  rm -rf ~/.config/{electron-flags.conf,hypr,kitty,uwsm,walker,elephant,waybar,xdg-terminals.list}
  stow -vS electron GTK hypr kitty nautilus-actions uwsm walker waybar xdg-terminal-exec
  if [[ ! "$SET_SOL" =~ ^[Nn]$ ]]; then
    rm -rf ~/config/solaar
    stow -vS solaar
  fi
)
