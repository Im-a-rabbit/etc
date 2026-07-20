#!/bin/bash
set -euo pipefail
NOTES=$(mktemp)
trap 'rm -rf "$NOTES" "$PWD/paru-git"' EXIT

note() {
  printf "%b\n" "$1" >>"$NOTES"
}

require_file() {
  if [ ! -f "$1" ]; then
    echo "Ошибка: $1 не найден."
    echo "Склонируйте репозиторий конфигов:"
    echo "git clone --depth=1 https://git.postmodernist.ru/Rabbit/etc ~/etc"
    exit 1
  fi
}

# ---------- пакеты ----------
pkgs=(
  plzip ntfs-3g ntfsprogs zip unzip
  pipewire{,-pulse,-jack,-alsa}
  wireplumber rtkit
  alsa-utils gstreamer gst-libav
  gst-plugin-pipewire
  gst-plugins-{base,good,bad,ugly}
  gst-plugin-va wiremix
  ffmpeg imagemagick v4l2loopback-dkms
  fish pkgfile fd ripgrep lsd bat
  impala bluetui btop fastfetch
  brightnessctl ddcutil man-pages-ru

)

# ---------- проверки ----------
if ((EUID == 0)); then
  echo "Не запускайте post-install от root."
  exit 1
fi

require_file ~/etc/post-conf/paru.conf

echo "Проверка соединения..."
if ! ping -c1 archlinux.org; then
  echo "Ошибка: нет интернета. Подключитесь к сети и перезапустите скрипт."
  exit 1
fi

# ---------- обновление системы ----------
echo "Обновление системы..."
sudo pacman -Syu --noconfirm
sudo timedatectl set-ntp true

# ---------- СВОбода? ----------
read -rp "Использовать AWG для скачивания пакетов? [y/N]: " SETUP_AWG
if [[ ! "$SETUP_AWG" =~ ^[Yy]$ && ! -f ~/etc/awg0.conf ]]; then
  echo -e "\033[31mСкопируйте ваш конфиг awg в ~/etc/awg0.conf и перезапустите скрипт\033[0m"
  exit 0
fi

# ---------- проверка Secure Boot Setup Mode ----------
read -rp "Настроить Secure Boot? [Y/n]: " SETUP_SB
if [[ ! "$SETUP_SB" =~ ^[Nn]$ ]]; then
  echo "Проверка статуса Secure Boot..."
  sudo pacman -S --needed --noconfirm sbctl
  if ! sbctl status | grep -q "Setup Mode:.*Enabled"; then
    echo "Ошибка: Secure Boot Setup Mode не активен."
    echo "Включите его в BIOS (обычно 'Setup Mode' или 'Clear Secure Boot Keys') и перезапустите скрипт."
    exit 1
  fi
  echo "Secure Boot Setup Mode активен."
fi

# ---------- вопросы ----------
read -rp "Установить Limine и настроить dual-boot? [Y/n]: " SETUP_LIMINE
if [[ ! "$SETUP_LIMINE" =~ ^[Nn]$ ]]; then
  require_file ~/etc/post-conf/limine
  require_file ~/etc/post-conf/bg.png
  pkgs+=(limine-mkinitcpio-hook)
  read -rp "  Найти и добавить существующие .efi в меню Limine? [Y/n]: " ADD_EFI
  read -rp "  Установить Memtest86+? [Y/n]: " ADD_MEMTEST
  [[ ! "$ADD_MEMTEST" =~ ^[Nn]$ ]] && pkgs+=(memtest86+-efi)
fi

read -rp "Настроить Bluetooth? [Y/n]: " SETUP_BT
if [[ ! "$SETUP_BT" =~ ^[Nn]$ ]]; then
  require_file ~/etc/post-conf/pipewire-bluetooth-autoconnect.service
  pkgs+=(bluez bluez-utils bluetooth-autoconnect) # TODO: написать свой autoconnect
fi

read -rp "Установить rustup вместо rust? [Y/n]: " SET_RUSTUP
read -rp "Установить мои .dotfiles и настроить stow? [Y/n]: " SET_DOTFILES
[[ ! "$SET_DOTFILES" =~ ^[Nn]$ ]] && pkgs+=(stow tree-sitter-cli python-pynvim npm)

read -rp "Git email: " GIT_EMAIL
read -rp "Git имя: " GIT_NAME

# ---------- установка rust ----------
if [[ ! "$SET_RUSTUP" =~ ^[Nn]$ ]]; then
  sudo pacman -S --needed --noconfirm rustup lldb
  rustup default stable
else
  sudo pacman -S --needed --noconfirm rust
fi

# ---------- AUR-помощник ----------
if ! command -v paru >/dev/null 2>&1; then
  echo "Установка paru..."
  git clone --depth=1 https://aur.archlinux.org/paru-git.git
  (
    cd paru-git
    makepkg -si --noconfirm
  )
else
  echo "paru уже установлен."
fi

sudo install -Dm644 ~/etc/post-conf/paru.conf /etc/

# ---------- СВОбода ----------
if [[ ! "$SETUP_AWG" =~ ^[Yy]$ ]]; then
  paru -S --failfast --needed --noconfirm amneziawg-{dkms,tools}
  sudo install -Dm600 ~/etc/awg0.conf /etc/amnezia/amneziawg/awg0.conf
  sudo awg-quick up awg0
  trap '
  sudo awg-quick down awg0 2>/dev/null || true
  rm -rf "$NOTES" "$PWD/paru-git"
  ' EXIT
  echo "Проверка соединения..."
  if ! ping -c1 archlinux.org; then
    echo "Ошибка: туннель не предостовляет выхода в интернет. Подключитесь к сети и перезапустите скрипт."
    exit 1
  fi
else
  pkgs+=(amneziawg-{dkms,tools})
fi

# ---------- установка пакетов ----------
echo "Установка пакетов..."
paru -S --failfast --needed --noconfirm "${pkgs[@]}"

# ---------- дополнительные настройки ----------
systemctl --user enable pipewire-pulse.service
echo "Настройка fish..."
sudo chsh -s "$(command -v fish)" "$USER"
sudo chsh -s "$(command -v fish)" root
echo "Настройка pkgfile..."
sudo pkgfile -u
sudo systemctl enable pkgfile-update.timer
echo "Настройка git..."
install -Dm644 ~/etc/post-conf/git ~/.config/git/config
git config --global user.email "$GIT_EMAIL"
git config --global user.name "$GIT_NAME"

# ---------- bluetooth ----------
if [[ ! "$SETUP_BT" =~ ^[Nn]$ ]]; then
  echo "Настройка Bluetooth..."
  sudo systemctl enable --now bluetooth
  install -Dm644 ~/etc/post-conf/pipewire-bluetooth-autoconnect.service ~/.config/systemd/user/
  systemctl --user enable pipewire-bluetooth-autoconnect.service
  sudo systemctl enable bluetooth-autoconnect.service
fi

# ---------- Secure Boot ----------
if [[ ! "$SETUP_SB" =~ ^[Nn]$ ]]; then
  echo "Настройка Secure Boot..."
  if ! sbctl status | grep -q "Installed:.*✓"; then
    sudo sbctl create-keys
    sudo sbctl enroll-keys -m
    sudo mkinitcpio -P
  fi
  note "\033[31mНе забудьте включить Secure Boot.\033[0m\n"
fi

# ---------- загрузчик Limine и мультисистемность ----------
if [[ ! "$SETUP_LIMINE" =~ ^[Nn]$ ]]; then
  echo "Установка Limine..."
  sudo install -Dm644 ~/etc/post-conf/limine /etc/default/limine
  sudo install -m700 ~/etc/post-conf/bg.png /boot/
  sudo sed -iE '
    /^### (Read more at config document:.*|Theme|.*hash mismatch|Hide Limine|Boot the default entry)$/d
    /^### Auto-generated by limine-entry-tool:/{N;d}
    /^#default_entry: <OS name>\/<kernel name>$/d
    s/^#interface_branding: Your boot manager$/interface_branding: I use Arch, btw/
    /^timeout:.*$/{s//timeout: 1/;n;/^$/d}
    s/^#?remember_last_entry:.*$/remember_last_entry: yes/
    /^#interface_help_color:/a\wallpaper: boot():/bg.png
  ' /boot/limine.conf

  [[ ! "$ADD_EFI" =~ ^[Nn]$ ]] && sudo limine-scan

  if [[ ! "$ADD_MEMTEST" =~ ^[Nn]$ ]]; then
    sudo limine-entry-tool --add-efi Memtest /boot/memtest86+/memtest.efi
    if [[ ! "$SETUP_SB" =~ ^[Nn]$ ]]; then
      sudo sbctl sign -s /boot/memtest86+/memtest.efi
    fi
  fi
  note "\033[33mМожете удалить ненужную запись efibootmgr,"
  note "если создавали до этого: sudo efibootmgr -Bb <номер>\033[0m\n"
fi

# ---------- настройка .dotfiles ----------
if [[ ! "$SET_DOTFILES" =~ ^[Nn]$ ]]; then
  echo "Установка .dotfiles и stow..."
  rm -rf ~/.dotfiles
  git clone --depth=1 https://git.postmodernist.ru/Rabbit/.dotfiles ~/.dotfiles
  (
    cd ~/.dotfiles
    rm -rf ~/.config/{btop,fastfetch,fish,nvim}
    stow -vS btop fastfetch fish nvim
  )
  sudo npm install -g neovim
  note "Подробности конфигураций можно узнать в моей инструкции.\n"
fi

note "\033[32mВы можете использовать ~/etc/gui.sh, чтобы установить графическое окружение.\033[0m"
note "\033[31mКрайне желательно перезагрузиться.\033[0m"
# ---------- завершение ----------
echo
echo "======================= Советы по дальнейшей настройке ======================="
cat "$NOTES"
echo "============================ Post-install завершён ============================"
echo "                                Приятной работы!"
