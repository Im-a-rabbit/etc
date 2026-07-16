#!/bin/bash
set -euo pipefail
trap '
umount -R /mnt 2>/dev/null || true
[[ -n "$SWAP" ]] && swapoff "$SWAP" 2>/dev/null || true
' EXIT
setfont ter-u32b

# ---------- пакеты ----------
pkgs=(
  base{,-devel}
  linux-{zen,zen-headers,firmware}
  kernel-modules-hook mold pigz pbzip2
  systemd-resolvconf iwd wireless-regdb
  ufw axel pacman-contrib
  terminus-font plymouth
  polkit nvim git less
  openssh bash-completion gpm
)

# ---------- проверка root ----------
if ((EUID != 0)); then
  echo "Запустите скрипт от имени root."
  exit 1
fi

# ---------- монтирование ----------
if mountpoint -q /mnt; then
  echo "Ошибка: /mnt занят. Освободите /mnt и перезапустите скрипт."
  exit 1
fi

if mountpoint -q /mnt/boot; then
  echo "Ошибка: /mnt/boot занят. Освободите /mnt/boot и перезапустите."
  exit 1
fi

read -rp "Корневой раздел (например /dev/nvme0n1p3): " ROOT
mount "$ROOT" /mnt

read -rp "ESP-раздел (например /dev/nvme0n1p1): " ESP
mount -m -o umask=0077 "$ESP" /mnt/boot

read -rp "Swap-раздел (пусто, если не нужен): " SWAP
[[ -n "$SWAP" ]] && swapon "$SWAP"

# выбор микрокода
select ucode_choice in "intel-ucode" "amd-ucode"; do
  case $ucode_choice in
  "") echo "Неверный выбор" ;;
  *)
    pkgs+=("$ucode_choice")
    break
    ;;
  esac
done

# архитектура для makepkg
echo "Выберите архитектуру процессора:"
select march_choice in "raptorlake" "native" "x86-64-v3" "x86-64-v4" "other"; do
  case $march_choice in
  other)
    read -rp "Введите архитектуру (например znver4): " MARCH
    break
    ;;
  "") echo "Неверный выбор" ;;
  *)
    MARCH=$march_choice
    break
    ;;
  esac
done

# Видеодрайвер
read -rp "Настроить драйверы NVIDIA? [Y/n]: " SETUP_NVIDIA
[[ ! "$SETUP_NVIDIA" =~ ^[Nn]$ ]] && pkgs+=(nvidia-open-dkms libva-nvidia-driver opencl-nvidia)
# FIX: Ранняя загрузка модулей nvidia препятствует нормальному выходу из гибернации

# CPU Power
read -rp "Настроить power-profiles? [Y/n]: " SETUP_PWP
[[ ! "$SETUP_PWP" =~ ^[Nn]$ ]] && pkgs+=(power-profiles-daemon python-gobject)
read -rp "Настроить Intel-undervolt? [Y/n]: " SETUP_INTEL
[[ ! "$SETUP_INTEL" =~ ^[Nn]$ ]] && pkgs+=(intel-undervolt)

# регион wireless-regdb
read -rp "Регион для wireless-regdb [RU]: " REGDOM
REGDOM=${REGDOM:-RU}
grep -Eq "^#?WIRELESS_REGDOM=\"$REGDOM\"" /etc/conf.d/wireless-regdom || {
  echo "Ошибка: неизвестный регион \"$REGDOM\"."
  exit 1
}

# systemd-networkd-wait-online.service.d/override.conf
read -rp "Ожидать готовности любого сетевого интерфейса вместо ожидания всех? [Y/n]: " WAIT_ONLINE_ANY

# часовой пояс
read -rp "Часовой пояс [Europe/Moscow]: " TIMEZONE
TIMEZONE=${TIMEZONE:-Europe/Moscow}
[ -e "/usr/share/zoneinfo/$TIMEZONE" ] || {
  echo "Ошибка: часовой пояс \"$TIMEZONE\" не существует."
  exit 1
}

# язык системы
read -rp "Язык системы (ru_RU/en_US) [ru_RU]: " LANG_CHOICE
LANG_CHOICE="${LANG_CHOICE:-ru_RU}.UTF-8"
grep -Eq "^#?$LANG_CHOICE UTF-8" /etc/locale.gen || {
  echo "Ошибка: локаль \"$LANG_CHOICE\" не найдена."
  exit 1
}

# ---------- вопросы ----------
read -rp "Отключить watchdog (RebootWatchdogSec=0)? [Y/n]: " SET_WATCHDOG
read -rp "Отключить пищалку (bell-style none в /etc/inputrc)? [Y/n]: " SET_BELL
read -rp "Имя компьютера: " HOSTNAME
read -rp "Имя пользователя: " USERNAME
read -rsp "Пароль $USERNAME:" USER_PASS
echo
read -rsp "Пароль root:" ROOT_PASS
echo
read -rp "Заблокировать вход по паролю для root? [Y/n]: " SET_ROOT

# ---------- установка пакетов ----------
reflector -c RU -l 10 --sort rate --save /etc/pacman.d/mirrorlist
sed -i 's/^.*ParallelDownloads.*/ParallelDownloads = 15/' /etc/pacman.conf
pacstrap -K /mnt "${pkgs[@]}"

# ---------- fstab ----------
genfstab -U /mnt >>/mnt/etc/fstab

# ---------- esp ----------
if [ -f /mnt/boot/EFI/BOOT/BOOTX64.EFI ]; then
  mv /mnt/boot/EFI/BOOT/bootx64{,_old}.efi
  echo "Резервный загрузчик переименован в bootx64_old.efi"
else
  mkdir -p /mnt/boot/EFI/BOOT
fi

# ---------- cmdline ----------
echo "root=UUID=$(blkid -s UUID -o value "$ROOT") rw quiet splash" >/mnt/etc/kernel/cmdline

# ---------- chroot ----------
arch-chroot /mnt /bin/bash <<EOF
set -euo pipefail

# время
ln -sf /usr/share/zoneinfo/"$TIMEZONE" /etc/localtime
hwclock --systohc

# локаль
sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
[ "$LANG_CHOICE" != "en_US.UTF-8" ] && sed -i "s/^#${LANG_CHOICE} UTF-8/${LANG_CHOICE} UTF-8/" /etc/locale.gen
locale-gen
echo "LANG=$LANG_CHOICE" > /etc/locale.conf
echo -e "KEYMAP=ruwin_alt_sh-UTF-8\nFONT=ter-u22b" > /etc/vconsole.conf

# пользователи
echo "$HOSTNAME" > /etc/hostname
echo "root:$ROOT_PASS" | chpasswd
useradd -mG wheel "$USERNAME"
echo "$USERNAME:$USER_PASS" | chpasswd
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

# клонирование и копирование конфигов
su "$USERNAME" -c "cd && git clone --depth=1 https://git.postmodernist.ru/Rabbit/etc"
(
  cd /home/"$USERNAME"/etc/early-conf
  install -Dm440 10-defaults /etc/sudoers.d/
  install -Dm644 mkinitcpio.conf /etc/
  install -Dm644 vtrgb /etc/vtrgb
  install -Dm644 vconsole-override.conf /etc/systemd/system/systemd-vconsole-setup.service.d/override.conf
  install -Dm644 linux-zen.preset /etc/mkinitcpio.d/
  install -Dm644 pacman.conf /etc/
  install -Dm644 makepkg.conf /etc/
  install -Dm644 env.sh /etc/profile.d/
  install -Dm644 network/*.network /etc/systemd/network/
  [[ ! "$WAIT_ONLINE_ANY" =~ ^[Nn]$ ]] && install -Dm644 network/override.conf /etc/systemd/system/systemd-networkd-wait-online.service.d/override.conf
  if [[ ! "$SETUP_INTEL" =~ ^[Nn]$ ]]; then
    install -Dm644 intel-undervolt.conf /etc/
    systemctl enable intel-undervolt.service
  fi
)

# правка makepkg.conf, если архитектура не raptorlake
[ "$MARCH" != "raptorlake" ] && sed -i "s/raptorlake/$MARCH/g" /etc/makepkg.conf

# сеть
systemctl enable iwd systemd-networkd systemd-resolved
sed -i "s/^#WIRELESS_REGDOM=\"$REGDOM\"/WIRELESS_REGDOM=\"$REGDOM\"/" /etc/conf.d/wireless-regdom

# дополнительно
rm -f /boot/*.img
systemctl enable paccache.timer
systemctl enable gpm
ufw enable
systemctl enable ufw
[[ ! "$SET_WATCHDOG" =~ ^[Nn]$ ]] && sed -i 's/^.*RebootWatchdogSec=.*/RebootWatchdogSec=0/' /etc/systemd/system.conf
[[ ! "$SET_BELL" =~ ^[Nn]$ ]] && sed -i 's/^.*set bell-style none/set bell-style none/' /etc/inputrc
[[ ! "$SET_ROOT" =~ ^[Nn]$ ]] && passwd -l root

# UKI
mkinitcpio -P
EOF

# ---------- Efi-запись ----------
read -rp "Добавить запись в UEFI для Arch? (Нужно, если на раздел уже ссылается какая-то запись) [y/N]: " ADD_UEFI
if [[ "$ADD_UEFI" =~ ^[Yy]$ ]]; then
  DISK="/dev/$(lsblk -no PKNAME "$ESP")"
  PART_NUM=$(lsblk -no PARTN "$ESP")
  efibootmgr -c -d "$DISK" -p "$PART_NUM" -L "Arch Linux" -l /EFI/BOOT/BOOTX64.EFI -u
fi

# ------ замена resolv.conf на ссылку ------
ln -sf ../run/systemd/resolve/stub-resolv.conf /mnt/etc/resolv.conf

echo
echo "=============================== Установка завершена ==============================="
echo "Перезагрузитесь (reboot) и запустите ~/etc/post-install.sh для завершения установки."
