#!/bin/bash
set -euo pipefail
setfont ter-u32b

die() {
  echo "Ошибка: $*" >&2
  exit 1
}

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

# ---------- валидация окружения ----------
((EUID == 0)) || die "Запустите скрипт от имени root."
mountpoint -q /mnt && die "/mnt занят. Освободите /mnt и перезапустите скрипт."
mountpoint -q /mnt/boot && die "/mnt/boot занят. Освободите /mnt/boot и перезапустите."

# ---------- подготовка chroot-скрипта ----------
# TODO: зафиксировать на тег.
CHROOT_URL="https://git.postmodernist.ru/Rabbit/etc/raw/branch/master/chroot-setup.sh"
curl -fsSL "$CHROOT_URL" -o /tmp/chroot-setup.sh || die "не удалось скачать chroot-setup.sh."

# ---------- выбор разделов ----------
read -rp "Корневой раздел (например /dev/nvme0n1p3): " ROOT
[[ -b "$ROOT" ]] || die "$ROOT не является блочным устройством."
ROOT_UUID=$(blkid -s UUID -o value "$ROOT")
[[ "$ROOT_UUID" != "$(findmnt -no UUID /)" ]] || die "$ROOT является корнем текущей системы."

read -rp "ESP-раздел (например /dev/nvme0n1p1): " ESP
[[ -b "$ESP" ]] || die "$ESP не является блочным устройством."

read -rp "Swap-раздел (пусто, если не нужен): " SWAP
[[ -z "$SWAP" || -b "$SWAP" ]] || die "$SWAP не является блочным устройством."

# ---------- параметры установки ----------
PS3="Микрокод: "
select ucode_choice in "intel-ucode" "amd-ucode"; do
  [[ -n $ucode_choice ]] && break
done
pkgs+=("$ucode_choice")

PS3="Архитектура процессора: "
select MARCH in "raptorlake" "native" "x86-64-v3" "x86-64-v4" "other"; do
  [[ -n $MARCH ]] && break
done
[[ $MARCH == other ]] && read -rp "Введите архитектуру (например znver4): " MARCH
[[ $MARCH =~ ^[a-z0-9_-]+$ ]] || die "некорректная архитектура."

read -rp "Установить power-profiles-daemon? [Y/n]: " SETUP_PWP
[[ ! "$SETUP_PWP" =~ ^[Nn]$ ]] && pkgs+=(power-profiles-daemon python-gobject)
read -rp "Настроить Intel-undervolt? [Y/n]: " SETUP_INTEL
[[ ! "$SETUP_INTEL" =~ ^[Nn]$ ]] && pkgs+=(intel-undervolt)

read -rp "Установить драйверы NVIDIA? [Y/n]: " SETUP_NVIDIA
[[ ! "$SETUP_NVIDIA" =~ ^[Nn]$ ]] && pkgs+=(nvidia-open-dkms libva-nvidia-driver opencl-nvidia)

read -rp "Ожидать готовности любого сетевого интерфейса вместо всех? [Y/n]: " WAIT_ONLINE_ANY

read -rp "Регион для wireless-regdb [RU]: " REGDOM
grep -Fq "WIRELESS_REGDOM=\"${REGDOM:=RU}\"" /etc/conf.d/wireless-regdom ||
  die "неизвестный регион \"$REGDOM\"."

read -rp "Часовой пояс [Europe/Moscow]: " TIMEZONE
[[ -e "/usr/share/zoneinfo/${TIMEZONE:=Europe/Moscow}" ]] ||
  die "часовой пояс \"$TIMEZONE\" не существует."

read -rp "Язык системы [ru_RU]: " LANG_CHOICE
LANG_CHOICE="${LANG_CHOICE:-ru_RU}.UTF-8"
grep -Fq "$LANG_CHOICE UTF-8" /etc/locale.gen ||
  die "локаль \"$LANG_CHOICE\" не найдена."

read -rp "Имя компьютера: " TARGET_HOST
[[ $TARGET_HOST =~ ^[a-zA-Z0-9][a-zA-Z0-9-]{0,62}$ ]] || die "некорректное имя компьютера."
read -rp "Имя пользователя: " USERNAME
[[ $USERNAME =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "некорректное имя пользователя."
read -rsp "Пароль $USERNAME: " USER_PASS
echo
read -rsp "Пароль root: " ROOT_PASS
echo

read -rp "Добавить запись в UEFI для Arch? (Нужно, если на раздел уже ссылается какая-то запись) [y/N]: " ADD_UEFI

# ---------- монтирование ----------
trap '[[ -n "${SWAP:-}" ]] && swapoff "$SWAP"; umount -R /mnt' EXIT
mount "$ROOT" /mnt
mount -m -o umask=0077 "$ESP" /mnt/boot
[[ -n "$SWAP" ]] && swapon "$SWAP"

# ---------- установка ----------
reflector -c RU -l 10 --sort rate --save /etc/pacman.d/mirrorlist
sed -i 's/^.*ParallelDownloads.*/ParallelDownloads = 15/' /etc/pacman.conf
pacstrap -K /mnt "${pkgs[@]}"
genfstab -U /mnt >>/mnt/etc/fstab

# ---------- ESP ----------
if [[ -f /mnt/boot/EFI/BOOT/BOOTX64.EFI ]]; then
  mv /mnt/boot/EFI/BOOT/bootx64{,_old}.efi
  echo "Резервный загрузчик переименован в bootx64_old.efi"
else
  mkdir -p /mnt/boot/EFI/BOOT
fi

# ---------- cmdline ----------
printf 'root=UUID=%s rw quiet splash loglevel=3\n' "$ROOT_UUID" >/mnt/etc/kernel/cmdline

# ---------- chroot ----------
mv /tmp/chroot-setup.sh /mnt/root/chroot-setup.sh
chmod +x /mnt/root/chroot-setup.sh
arch-chroot /mnt /root/chroot-setup.sh \
  "$TIMEZONE" "$LANG_CHOICE" "$TARGET_HOST" "$USERNAME" "$WAIT_ONLINE_ANY" \
  "$SETUP_INTEL" "$REGDOM" "$ROOT_PASS" "$USER_PASS"
rm -f /mnt/root/chroot-setup.sh

# ---------- коррекция makepkg.conf ----------
sed -i "s/CHANGE_ME/$MARCH/g" /mnt/etc/makepkg.conf

# ---------- запись UEFI ----------
if [[ "$ADD_UEFI" =~ ^[Yy]$ ]]; then
  DISK="/dev/$(lsblk -no PKNAME "$ESP")"
  PART_NUM=$(lsblk -no PARTN "$ESP")
  efibootmgr -c -d "$DISK" -p "$PART_NUM" -L "Arch Linux" -l /EFI/BOOT/BOOTX64.EFI -u
fi

# ---------- resolv.conf ----------
ln -sf ../run/systemd/resolve/stub-resolv.conf /mnt/etc/resolv.conf

echo
echo "=============================== Установка завершена ==============================="
echo "Перезагрузитесь (reboot) и запустите ~/etc/post-install.sh для завершения установки."
