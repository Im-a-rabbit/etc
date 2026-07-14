#!/bin/bash
set -euo pipefail
NOTES=$(mktemp)
trap 'rm -f "$NOTES"' EXIT

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

# ---------- проверка root ----------
if ((EUID == 0)); then
  echo "Не запускайте post-install от root."
  exit 1
fi

# ---------- проверка сети ----------
echo "Проверка соединения..."
if ! ping -c 3 google.com; then
  echo "Ошибка: нет интернета. Подключитесь к сети и перезапустите скрипт."
  exit 1
fi

# ---------- обновление системы ----------
echo "Обновление системы..."
sudo pacman -Syu --noconfirm
sudo timedatectl set-ntp true

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

# ---------- проверка необходимых файлов ----------
read -rp "Установить Limine и настроить dual-boot? [Y/n]: " SETUP_LIMINE
if [[ ! "$SETUP_LIMINE" =~ ^[Nn]$ ]]; then
  read -rp "  Найти и добавить существующие .efi в меню Limine? [Y/n]: " ADD_EFI
  read -rp "  Установить Memtest86+? [Y/n]: " ADD_MEMTEST
  require_file ~/etc/post-conf/limine
fi

read -rp "Настроить драйверы NVIDIA? [Y/n]: " SETUP_NVIDIA

read -rp "Настроить Intel-undervolt и power-profiles? [Y/n]: " SETUP_INTEL
if [[ ! "$SETUP_INTEL" =~ ^[Nn]$ ]]; then
  require_file ~/etc/post-conf/intel-undervolt.conf
fi

read -rp "Настроить Bluetooth? [Y/n]: " SETUP_BT
if [[ ! "$SETUP_BT" =~ ^[Nn]$ ]]; then
  require_file ~/etc/post-conf/pipewire-bluetooth-autoconnect.service
fi

# ---------- вопросы ----------
read -rp "Установить rustup вместо rust? [Y/n]: " SET_RUSTUP
read -rp "Отключить watchdog? [Y/n]: " SET_WATCHDOG
read -rp "Отключить пищалку (bell-style none в /etc/inputrc)? [Y/n]: " SET_BELL
read -rp "Установить русские man-страницы (man-pages-ru)? [Y/n]: " SET_MAN_RU
read -rp "Заблокировать вход по паролю для root? [Y/n]: " SET_ROOT
read -rp "Git email: " GIT_EMAIL
read -rp "Git имя: " GIT_NAME
read -rp "Установить мои .dotfiles и настроить stow? [Y/n]: " SET_DOTFILES

# ---------- установка rust ----------
if [[ ! "$SET_RUSTUP" =~ ^[Nn]$ ]]; then
  sudo pacman -S --needed --noconfirm rustup
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
  rm -rf ~/paru-git
else
  echo "paru уже установлен."
fi

sudo install -Dm 644 ~/etc/post-conf/paru.conf /etc/
paru_install() {
  paru -S --failfast --needed --noconfirm "$@"
}

# ---------- основные пакеты ----------
echo "Установка основных пакетов..."
paru_install plzip ntfs-3g alsa-utils ufw \
  pipewire{,-pulse,-jack,-alsa} wireplumber rtkit wiremix

systemctl --user enable pipewire-pulse.service

# ---------- брандмауэр ----------
echo "Настройка брандмауэра..."
sudo ufw enable
sudo systemctl enable ufw
note "Открывать порты можно так: sudo ufw allow 25565/tcp comment 'minecraft'\n"

# ---------- bluetooth ----------
if [[ ! "$SETUP_BT" =~ ^[Nn]$ ]]; then
  echo "Настройка Bluetooth..."
  paru_install bluez bluez-utils bluetooth-autoconnect
  sudo systemctl enable --now bluetooth
  install -D ~/etc/post-conf/pipewire-bluetooth-autoconnect.service ~/.config/systemd/user/
  systemctl --user enable pipewire-bluetooth-autoconnect.service
  sudo systemctl enable bluetooth-autoconnect.service
fi

# ---------- безопасность ----------
if [[ ! "$SET_ROOT" =~ ^[Nn]$ ]]; then
  echo "Блокировка root-пароля..."
  sudo passwd -l root
  note "Чтобы разблокировать root, используйте: sudo passwd -u root\n"
fi

# ---------- Secure Boot ----------
if [[ ! "$SETUP_SB" =~ ^[Nn]$ ]]; then
  echo "Настройка Secure Boot..."
  sudo sbctl create-keys
  sudo sbctl enroll-keys -m
  sudo mkinitcpio -P
fi

# ---------- специфичные драйверы ----------
if [[ ! "$SETUP_NVIDIA" =~ ^[Nn]$ ]]; then
  echo "Настройка драйверов NVIDIA..."
  paru_install nvidia-open-dkms libva-nvidia-driver opencl-nvidia
  # FIX: Ранняя загрузка модулей nvidia препятствует нормальному выходу из гибернации
  # sudo sed -i 's/^MODULES=()/MODULES=(i915 nvidia nvidia_modeset nvidia_uvm nvidia_drm)/' /etc/mkinitcpio.conf
  sudo mkinitcpio -P
fi

if [[ ! "$SETUP_INTEL" =~ ^[Nn]$ ]]; then
  echo "Настройка Intel-undervolt и power-profiles..."
  paru_install intel-undervolt power-profiles-daemon python-gobject
  sudo install -Dm 644 ~/etc/post-conf/intel-undervolt.conf /etc/
  sudo systemctl enable intel-undervolt.service
  note "Используйте powerprofilesctl get, чтобы узнать текущий профиль."
  note "powerprofilesctl set power-saver|balanced|performance, чтобы выставить.\n"
  note "Изменить лимиты питания можно в /etc/intel-undervolt.conf\n"
fi

# ---------- загрузчик Limine и мультисистемность ----------
if [[ ! "$SETUP_LIMINE" =~ ^[Nn]$ ]]; then
  echo "Установка Limine..."
  paru_install limine-mkinitcpio-hook
  sudo install -Dm 644 ~/etc/post-conf/limine /etc/default/limine

  if [[ ! "$ADD_EFI" =~ ^[Nn]$ ]]; then
    sudo limine-scan
  fi

  if [[ ! "$ADD_MEMTEST" =~ ^[Nn]$ ]]; then
    paru_install memtest86+-efi
    sudo limine-entry-tool --add-efi Memtest /boot/memtest86+/memtest.efi
    if [[ ! "$SETUP_SB" =~ ^[Nn]$ ]]; then
      sudo sbctl sign -s /boot/memtest86+/memtest.efi
    fi
  fi
  note "\033[33mМожете удалить ненужную запись efibootmgr,"
  note "если создавали до этого: sudo efibootmgr -Bb <номер>\n"
  note "Не забудьте настроить /boot/limine.conf\033[0m\n"
fi

# ---------- отключение пищалки ----------
if [[ ! "$SET_BELL" =~ ^[Nn]$ ]]; then
  sudo sed -i 's/^.*set bell-style none/set bell-style none/' /etc/inputrc
  echo "Пищалка отключена в /etc/inputrc"
fi

# ---------- watchdog ----------
if [[ ! "$SET_WATCHDOG" =~ ^[Nn]$ ]]; then
  echo "Отключение watchdog..."
  sudo sed -i 's/^.*RebootWatchdogSec=.*/RebootWatchdogSec=0/' /etc/systemd/system.conf
  echo "RebootWatchdogSec установлен в 0."
fi

# ---------- русские man-страницы ----------
if [[ ! "$SET_MAN_RU" =~ ^[Nn]$ ]]; then
  paru_install man-pages-ru
  note "Используйте man с названием нужной статьи, если знаете его,"
  note "man -k для поиска совпадений в названии"
  note "и man -K для поиска внутри статей.\n"
fi

# ---------- полезные TUI/CLI утилиты ----------
echo "Установка консольных утилит..."
paru_install \
  fish pkgfile fd ripgrep lsd bat \
  luarocks lua51 tree-sitter-cli \
  nodejs npm impala bluetui btop \
  fastfetch brightnessctl ddcutil \
  ffmpeg imagemagick v4l2loopback-dkms \
  amneziawg-dkms amneziawg-tools

note "Список установленных пакетов можно найти в моей инструкции.\n"

# ---------- fish как основной шелл ----------
echo "Настройка fish..."
sudo chsh -s "$(command -v fish)" "$USER"
sudo chsh -s "$(command -v fish)" root

# ---------- pkgfile ----------
echo "Настройка pkgfile..."
sudo pkgfile -u
sudo systemctl enable pkgfile-update.timer

# ---------- настройка git ----------
echo "Настройка git..."
install -D /dev/null ~/.config/git/config
git config --global user.email "$GIT_EMAIL"
git config --global user.name "$GIT_NAME"
git config --global core.editor "nvim"
git config --global core.pager "less -Fr"
git config --global init.defaultBranch master

# ---------- настройка .dotfiles ----------
if [[ ! "$SET_DOTFILES" =~ ^[Nn]$ ]]; then
  echo "Установка .dotfiles и stow..."
  paru_install stow
  git clone --depth=1 https://git.postmodernist.ru/Rabbit/.dotfiles ~/.dotfiles
  cd ~/.dotfiles
  rm -rf ~/.config/{btop,fastfetch,fish,nvim}
  stow -vS btop fastfetch fish nvim
  note "Подробности конфигураций можно узнать в моей инструкции.\n"
fi

note "\033[32mВы можете использовать ~/etc/gui.sh, чтобы установить графическое окружение.\033[0m"
note "\033[31mКрайне желательно перезагрузиться и включить Secure Boot.\033[0m"
# ---------- завершение ----------
rm -rf ~/etc/post-conf
echo
echo "======================= Советы по дальнейшей настройке ======================="
cat "$NOTES"
echo "============================ Post-install завершён ============================"
echo "                                Приятной работы!"
