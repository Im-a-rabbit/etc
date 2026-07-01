#!/bin/bash
set -e
NOTES=$(mktemp)
trap 'rm -f "$NOTES"' EXIT

# ---------- Проверка сети ----------
echo "Проверка соединения..."
if ! ping -c 3 google.com; then
    echo "Ошибка: нет интернета. Подключитесь к сети и перезапустите скрипт."
    exit 1
fi

# ---------- Обновление системы ----------
echo "Обновление системы..."
sudo pacman -Syu --noconfirm
sudo timedatectl set-ntp true

# ---------- Проверка Secure Boot Setup Mode ----------
read -p "Настроить Secure Boot? [Y/n]: " SETUP_SB
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

# ---------- Проверка необходимых файлов ----------
read -p "Установить Limine и настроить dual-boot? [Y/n]: " SETUP_LIMINE
if [[ ! "$SETUP_LIMINE" =~ ^[Nn]$ ]]; then
    read -p "  Найти и добавить Windows в меню Limine? [Y/n]: " ADD_WIN
    read -p "  Установить Memtest86+? [Y/n]: " ADD_MEMTEST
		if [ ! -f ~/etc/post-conf/limine ]; then
				echo "Ошибка: ~/etc/post-conf/limine не найден."
				echo "Склонируйте репозиторий конфигов: git clone --depth=1 https://git.postmodernist.ru/Rabbit/etc ~/etc"
				exit 1
		fi
fi

read -p "Настроить драйверы NVIDIA? [Y/n]: " SETUP_NVIDIA
if [[ ! "$SETUP_NVIDIA" =~ ^[Nn]$ ]] && [ ! -f ~/etc/post-conf/nvidia.conf ]; then
    echo "Ошибка: ~/etc/post-conf/nvidia.conf не найден."
    echo "Склонируйте репозиторий конфигов: git clone --depth=1 https://git.postmodernist.ru/Rabbit/etc ~/etc"
    exit 1
fi

read -p "Настроить Intel-undervolt и power-profiles? [Y/n]: " SETUP_INTEL
if [[ ! "$SETUP_INTEL" =~ ^[Nn]$ ]] && [ ! -f ~/etc/post-conf/intel-undervolt.conf ]; then
    echo "Ошибка: ~/etc/post-conf/intel-undervolt.conf не найден."
    echo "Склонируйте репозиторий конфигов: git clone --depth=1 https://git.postmodernist.ru/Rabbit/etc ~/etc"
    exit 1
fi

read -p "Настроить Bluetooth? [Y/n]: " SETUP_BT
if [[ ! "$SETUP_BT" =~ ^[Nn]$ ]] && [ ! -f ~/etc/post-conf/pipewire-bluetooth-autoconnect.service ]; then
    echo "Ошибка: ~/etc/post-conf/pipewire-bluetooth-autoconnect.service не найден."
    echo "Склонируйте репозиторий конфигов: git clone --depth=1 https://git.postmodernist.ru/Rabbit/etc ~/etc"
    exit 1
fi

# ---------- Вопросы ----------
read -p "Отключить watchdog? [Y/n]: " SET_WATCHDOG
read -p "Отключить пищалку (bell-style none в /etc/inputrc)? [Y/n]: " SET_BELL
read -p "Установить русские man-страницы (man-pages-ru)? [Y/n]: " SET_MAN_RU
read -p "Заблокировать вход по паролю для root? [Y/n]: " SET_ROOT
read -p "Git email: " GIT_EMAIL
read -p "Git имя: " GIT_NAME
read -p "Установить мои .dotfiles и настроить stow? [Y/n]: " SET_DOTFILES

# ---------- AUR-помощник ----------
echo "Установка yay..."
git clone --depth=1 https://aur.archlinux.org/yay.git
cd yay
makepkg -si --noconfirm
cd ..
rm -rf yay ~/.config/go
go telemetry off 2>/dev/null || true

# ---------- Основные пакеты ----------
echo "Установка основных пакетов..."
yay -S --needed --noconfirm plzip ntfs-3g alsa-utils \
    pipewire{,-pulse,-jack,-alsa} wireplumber rtkit wiremix \
    ufw

systemctl --user enable pipewire-pulse.service

# ---------- Брандмауэр ----------
echo "Настройка брандмауэра..."
sudo ufw enable
echo -e "Открывать порты можно так: sudo ufw allow 25565/tcp comment 'minecraft'\n" >> "$NOTES"

# ---------- Bluetooth ----------
if [[ ! "$SETUP_BT" =~ ^[Nn]$ ]]; then
    echo "Настройка Bluetooth..."
    yay -S --needed --noconfirm bluez bluez-utils bluetooth-autoconnect
    sudo systemctl enable --now bluetooth

    mkdir -p ~/.config/systemd/user
    cp ~/etc/post-conf/pipewire-bluetooth-autoconnect.service ~/.config/systemd/user/
    systemctl --user enable pipewire-bluetooth-autoconnect.service
    sudo systemctl enable bluetooth-autoconnect.service
fi

# ---------- Безопасность ----------
if [[ ! "$SET_ROOT" =~ ^[Nn]$ ]]; then
    echo "Блокировка root-пароля..."
    sudo passwd -l root
    echo -e "Чтобы разблокировать root, используйте: sudo passwd -u root\n" >> "$NOTES"
fi

# ---------- Secure Boot ----------
if [[ ! "$SETUP_SB" =~ ^[Nn]$ ]]; then
    echo "Настройка Secure Boot..."
    sudo sbctl create-keys
    sudo sbctl enroll-keys -m
    sudo mkinitcpio -P
fi

# ---------- Специфичные драйверы ----------
if [[ ! "$SETUP_NVIDIA" =~ ^[Nn]$ ]]; then
    echo "Настройка драйверов NVIDIA..."
    yay -S --needed --noconfirm nvidia-open-dkms
    sudo install -m 644 ~/etc/post-conf/nvidia.conf /etc/modprobe.d/
    sudo sed -i '1s/^#//' /etc/mkinitcpio.conf
    sudo sed -i '2d' /etc/mkinitcpio.conf
    sudo mkinitcpio -P
fi

if [[ ! "$SETUP_INTEL" =~ ^[Nn]$ ]]; then
    echo "Настройка Intel-undervolt и power-profiles..."
    yay -S --needed --noconfirm intel-undervolt power-profiles-daemon python-gobject
    sudo install -m 644 ~/etc/post-conf/intel-undervolt.conf /etc/
    sudo systemctl enable intel-undervolt.service
    echo -e "Используйте powerprofilesctl get, чтобы узнать текущий профиль." >> "$NOTES"
    echo -e "powerprofilesctl set power-saver|balanced|performance, чтобы выставить.\n" >> "$NOTES"
	echo -e "Изменить лимиты питания можно в /etc/intel-undervolt.conf\n" >> "$NOTES"
fi

# ---------- Загрузчик Limine и мультисистемность ----------
if [[ ! "$SETUP_LIMINE" =~ ^[Nn]$ ]]; then
    echo "Установка Limine..."
    yay -S --needed --noconfirm limine-mkinitcpio-hook
    sudo install -m 644 ~/etc/post-conf/limine /etc/default/limine

    if [[ ! "$ADD_WIN" =~ ^[Nn]$ ]]; then
        sudo limine-scan
    fi

    if [[ ! "$ADD_MEMTEST" =~ ^[Nn]$ ]]; then
        yay -S --needed --noconfirm memtest86+-efi
        sudo limine-entry-tool --add-efi Memtest /boot/memtest86+/memtest.efi
				if [[ ! "$SETUP_SB" =~ ^[Nn]$ ]]; then
					sudo sbctl sign -s /boot/memtest86+/memtest.efi
				fi
    fi
		echo -e "\033[33mМожете удалить ненужную запись efibootmgr, \nесли создавали до этого: sudo efibootmgr -Bb <номер>\n" >> "$NOTES"
		echo -e "Не забудьте настроить /boot/limine.conf\033[0m\n" >> "$NOTES"
fi

# ---------- Отключение пищалки ----------
if [[ ! "$SET_BELL" =~ ^[Nn]$ ]]; then
    sudo sed -i 's/^.*set bell-style none/set bell-style none/' /etc/inputrc
    echo "Пищалка отключена в /etc/inputrc"
fi

# ---------- Watchdog ----------
if [[ ! "$SET_WATCHDOG" =~ ^[Nn]$ ]]; then
    echo "Отключение watchdog..."
    sudo sed -i 's/^.*RebootWatchdogSec=.*/RebootWatchdogSec=0/' /etc/systemd/system.conf
    echo "RebootWatchdogSec установлен в 0."
fi

# ---------- Русские man-страницы ----------
if [[ ! "$SET_MAN_RU" =~ ^[Nn]$ ]]; then
    yay -S --needed --noconfirm man-pages-ru
    echo -e "Используйте man с названием нужной статьи, если знаете его, \nman -k для поиска совпадений в названии \nи man -K для поиска внутри статей.\n" >> "$NOTES"
fi

# ---------- Полезные TUI/CLI утилиты ----------
echo "Установка консольных утилит..."
yay -S --needed --noconfirm \
    fish pkgfile fd ripgrep lsd \
    luarocks lua51 tree-sitter-cli \
    fastfetch impala bluetui btop \
    brightnessctl ddcutil mpv \
    v4l2loopback-dkms amneziawg-dkms amneziawg-tools

echo -e "Список установленных пакетов можно найти в моей инструкции\n" >> "$NOTES"

# ---------- fish как основной шелл ----------
echo "Настройка fish..."
sudo chsh -s "$(command -v fish)" "$(whoami)"
sudo chsh -s "$(command -v fish)" root

# ---------- pkgfile ----------
echo "Настройка pkgfile..."
sudo pkgfile -u
sudo systemctl enable pkgfile-update.timer

# ---------- Настройка git ----------
echo "Настройка git..."
mkdir -p ~/.config/git
touch ~/.config/git/config
git config --global user.email "$GIT_EMAIL"
git config --global user.name "$GIT_NAME"
git config --global core.editor "nvim"
git config --global core.pager "less -Fr"
git config --global init.defaultBranch master

# ---------- Настройка .dotfiles ----------
if [[ ! "$SET_DOTFILES" =~ ^[Nn]$ ]]; then
    echo "Установка .dotfiles и stow..."
    yay -S --needed --noconfirm stow
    git clone --depth=1 https://git.postmodernist.ru/Rabbit/.dotfiles ~/.dotfiles
    cd ~/.dotfiles
    rm -rf ~/.config/fish
    stow -vS btop fastfetch fish nvim
    echo -e "Подробности конфигураций можно узнать в моей инструкции.\n" >> "$NOTES"
fi

# ---------- Завершение ----------
rm -rf ~/etc/post-conf/
echo
echo "======================= Советы по дальнейшей настройке ======================="
cat "$NOTES"
echo -e "\033[32mВы можете использовать ~/etc/gui.sh, чтобы установить графическое окружение\033[0m"
echo -e "\033[31mКрайне желательно перезагрузится и включить Secure Boot\033[0m"
echo "============================ Post-install завершён ============================"
echo "                                Приятной работы!"
