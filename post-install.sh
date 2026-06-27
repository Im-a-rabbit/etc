#!/bin/bash
set -e

# ---------- Проверка сети ----------
echo "Проверка соединения..."
if ! ping -c 3 google.com; then
    echo "Ошибка: нет интернета. Подключитесь к сети и перезапустите скрипт."
    exit 1
fi

# ---------- Проверка необходимых файлов ----------
read -p "Настроить Bluetooth? (Y/n): " SETUP_BT
if [[ ! "$SETUP_BT" =~ ^[Nn]$ ]] && [ ! -f ~/etc/pipewire-bluetooth-autoconnect.service ]; then
    echo "Ошибка: ~/etc/pipewire-bluetooth-autoconnect.service не найден."
    echo "Склонируйте репозиторий конфигов: git clone --depth=1 https://git.postmodernist.ru/Rabbit/etc ~/etc"
    exit 1
fi

read -p "Установить Limine и настроить dual‑boot? (Y/n): " SETUP_LIMINE
if [[ ! "$SETUP_LIMINE" =~ ^[Nn]$ ]]; then
    read -p "  Найти и добавить Windows в меню Limine? (Y/n): " ADD_WIN
    read -p "  Установить Memtest86+? (Y/n): " ADD_MEMTEST
		if [ ! -f ~/etc/limine ]; then
				echo "Ошибка: ~/etc/limine не найден."
				echo "Склонируйте репозиторий конфигов: git clone --depth=1 https://git.postmodernist.ru/Rabbit/etc ~/etc"
				exit 1
		fi
fi

read -p "Настроить драйверы NVIDIA? (Y/n): " SETUP_NVIDIA
if [[ ! "$SETUP_NVIDIA" =~ ^[Nn]$ ]] && [ ! -f ~/etc/nvidia.conf ]; then
    echo "Ошибка: ~/etc/nvidia.conf не найден."
    echo "Склонируйте репозиторий конфигов: git clone --depth=1 https://git.postmodernist.ru/Rabbit/etc ~/etc"
    exit 1
fi

read -p "Настроить Intel‑undervolt и power‑profiles? (Y/n): " SETUP_INTEL
if [[ ! "$SETUP_INTEL" =~ ^[Nn]$ ]] && [ ! -f ~/etc/intel-undervolt.conf ]; then
    echo "Ошибка: ~/etc/intel-undervolt.conf не найден."
    echo "Склонируйте репозиторий конфигов: git clone --depth=1 https://git.postmodernist.ru/Rabbit/etc ~/etc"
    exit 1
fi

# ---------- Проверка Secure Boot Setup Mode ----------
read -p "Настроить Secure Boot? (Y/n): " SETUP_SB
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

# ---------- Вопросы ----------
read -p "Отключить пищалку (bell-style none в /etc/inputrc)? (Y/n): " SET_BELL
read -p "Установить русские man-страницы (man-pages-ru)? (Y/n): " SET_MAN_RU
read -p "Git email: " GIT_EMAIL
read -p "Git имя: " GIT_NAME

# ---------- Обновление системы ----------
echo "Обновление системы..."
sudo pacman -Syu --noconfirm

# ---------- AUR-помощник ----------
echo "Установка yay..."
git clone --depth=1 https://aur.archlinux.org/yay.git
cd yay
makepkg -si --noconfirm
cd ..
rm -rf yay
rm -rf ~/.config/go
go telemetry off 2>/dev/null || true

# ---------- Основные пакеты ----------
echo "Установка основных пакетов..."
yay -S --noconfirm plzip ntfs-3g alsa-utils \
    pipewire{,-pulse,-jack,-alsa} wireplumber rtkit wiremix \
    ufw

systemctl --user enable pipewire-pulse.service

# ---------- Брандмауэр ----------
echo "Настройка брандмауэра..."
sudo ufw enable
sudo ufw status verbose

# ---------- Bluetooth (опционально) ----------
if [[ ! "$SETUP_BT" =~ ^[Nn]$ ]]; then
    echo "Настройка Bluetooth..."
    yay -S --noconfirm bluez bluez-utils bluetooth-autoconnect
    sudo systemctl enable --now bluetooth

    mkdir -p ~/.config/systemd/user
    mv ~/etc/pipewire-bluetooth-autoconnect.service ~/.config/systemd/user/
    systemctl --user enable pipewire-bluetooth-autoconnect.service
    sudo systemctl enable bluetooth-autoconnect.service
fi

# ---------- Безопасность ----------
echo "Блокировка root-пароля..."
sudo passwd -l root

# ---------- Secure Boot (опционально) ----------
if [[ ! "$SETUP_SB" =~ ^[Nn]$ ]]; then
    echo "Настройка Secure Boot..."
    sudo sbctl create-keys
    sudo sbctl enroll-keys -m
    sudo mkinitcpio -P
fi

# ---------- Специфичные драйверы ----------
if [[ ! "$SETUP_NVIDIA" =~ ^[Nn]$ ]]; then
    echo "Настройка драйверов NVIDIA..."
    yay -S --noconfirm nvidia-open-dkms
    sudo install -m 644 ~/etc/nvidia.conf /etc/modprobe.d/
		rm ~/etc/nvidia.conf
    sudo sed -i '1s/^#//' /etc/mkinitcpio.conf
    sudo sed -i '2d' /etc/mkinitcpio.conf
    sudo mkinitcpio -P
fi

if [[ ! "$SETUP_INTEL" =~ ^[Nn]$ ]]; then
    echo "Настройка Intel‑undervolt и power‑profiles..."
    yay -S --noconfirm intel-undervolt power-profiles-daemon python-gobject
    sudo install -m 644 ~/etc/intel-undervolt.conf /etc/
		rm ~/etc/intel-undervolt.conf
    sudo systemctl enable intel-undervolt.service
    echo "Используйте powerprofilesctl set power-saver|balanced|performance"
		echo "Измените лимиты питания по желанию в /etc/intel-undervolt.conf"
fi

# ---------- Загрузчик Limine и мультисистемность (опционально) ----------
if [[ ! "$SETUP_LIMINE" =~ ^[Nn]$ ]]; then
    echo "Установка Limine..."
    yay -S --noconfirm limine-mkinitcpio-hook
    sudo install -m 644 ~/etc/limine /etc/default/limine
		rm ~/etc/limine

    if [[ ! "$ADD_WIN" =~ ^[Nn]$ ]]; then
        sudo limine-scan
    fi

    if [[ ! "$ADD_MEMTEST" =~ ^[Nn]$ ]]; then
        yay -S --noconfirm memtest86+-efi
        sudo limine-entry-tool --add-efi Memtest /boot/memtest86+/memtest.efi
    fi
		echo "Можете удалить ненужную запись efibootmgr, если создавали до этого: sudo efibootmgr -Bb <номер>"
    echo "Не забудьте настроить /boot/limine.conf"
fi

# ---------- Отключение пищалки ----------
if [[ ! "$SET_BELL" =~ ^[Nn]$ ]]; then
    sudo sed -i 's/^# set bell-style none/set bell-style none/' /etc/inputrc
    echo "Пищалка отключена в /etc/inputrc"
fi

# ---------- Русские man-страницы ----------
if [[ ! "$SET_MAN_RU" =~ ^[Nn]$ ]]; then
    yay -S --noconfirm man-pages-ru
fi

# ---------- Полезные TUI/CLI утилиты ----------
echo "Установка консольных утилит..."
yay -S --noconfirm \
    fish pkgfile fd ripgrep lsd \
    luarocks lua51 tree-sitter-cli \
    fastfetch impala bluetui btop \
    brightnessctl ddcutil mpv \
    v4l2loopback-dkms amneziawg-dkms amneziawg-tools

# ---------- fish как основной шелл ----------
echo "Настройка fish..."
sudo chsh -s "$(command -v fish)" "$(whoami)"

# ---------- pkgfile ----------
echo "Настройка pkgfile..."
sudo pkgfile -u
sudo systemctl enable pkgfile-update.timer

# ---------- Настройка git ----------
echo "Настройка git..."
mkdir -p ~/.config/git
git config --global user.email "$GIT_EMAIL"
git config --global user.name "$GIT_NAME"
git config --global core.editor "nvim"
git config --global core.pager "less -Fr"
git config --global init.defaultBranch master

# ---------- Завершение ----------
echo
echo "=== Post‑install завершён ==="
echo "Осталось по желанию:"
echo "  - настроить stow для управления dotfiles"
echo "Можете использовать мой репозиторий конфигов: git clone --depth=1 https://git.postmodernist.ru/Rabbit/.dotfiles"
echo
echo "Приятной работы!"
