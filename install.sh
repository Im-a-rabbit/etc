#!/bin/bash
set -e
setfont ter-u32b

# ---------- проверка root ----------
if (( EUID != 0 )); then
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
read -p "ESP-раздел (например /dev/nvme0n1p1): " ESP
read -p "Swap-раздел (пусто, если не нужен): " SWAP
read -p "Корневой раздел (например /dev/nvme0n1p3): " ROOT
mount "$ROOT" /mnt
mount -m -o umask=0077 "$ESP" /mnt/boot
if [ -n "$SWAP" ]; then
		swapon "$SWAP"
fi

# ---------- вопросы ----------
read -p "Имя компьютера: " HOSTNAME
read -p "Имя пользователя: " USERNAME
echo "Пароль root:"
read -s ROOT_PASS
echo
echo "Пароль $USERNAME:"
read -s USER_PASS
echo

# выбор микрокода
select ucode_choice in "intel-ucode" "amd-ucode"; do
    UCODE_PKG=$ucode_choice
    break
done

# архитектура для makepkg
echo "Выберите архитектуру процессора:"
select march_choice in "raptorlake" "native" "x86-64-v3" "x86-64-v4" "other"; do
    case $march_choice in
        other) read -p "Введите архитектуру (например znver4): " MARCH; break;;
        "")     echo "Неверный выбор";;
        *)      MARCH=$march_choice; break;;
    esac
done

# регион wireless-regdb
read -p "Регион для wireless-regdb [RU]: " REGDOM
REGDOM=${REGDOM:-RU}

# часовой пояс
read -p "Часовой пояс [Europe/Moscow]: " TIMEZONE
TIMEZONE=${TIMEZONE:-Europe/Moscow}

# язык системы
read -p "Язык системы (ru_RU/en_US) [ru_RU]: " LANG_CHOICE
LANG_CHOICE=${LANG_CHOICE:-ru_RU}
LANG_FULL="${LANG_CHOICE}.UTF-8"

# ---------- установка пакетов ----------
reflector -c RU -l 10 --sort rate --save /etc/pacman.d/mirrorlist
sed -i 's/^.*ParallelDownloads.*/ParallelDownloads = 15/' /etc/pacman.conf

pacstrap -K /mnt base{,-devel} linux-{zen,zen-headers,firmware} "$UCODE_PKG" \
    systemd-resolvconf iwd wireless-regdb polkit axel mold pacman-contrib \
    pigz pbzip2 terminus-font plymouth nvim git less openssh bash-completion

# ---------- fstab ----------
genfstab -U /mnt >> /mnt/etc/fstab

# ---------- chroot-скрипт ----------
cat > /mnt/root/setup-chroot.sh << 'EOF'
#!/bin/bash
set -e

# время
ln -sf /usr/share/zoneinfo/"$TIMEZONE" /etc/localtime
hwclock --systohc
timedatectl set-timezone "$TIMEZONE"

# локаль
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
if [ "$LANG_FULL" != "en_US.UTF-8" ]; then
    echo "$LANG_FULL UTF-8" >> /etc/locale.gen
fi
locale-gen
echo "LANG=$LANG_FULL" > /etc/locale.conf
echo -e "KEYMAP=ruwin_alt_sh-UTF-8\nFONT=ter-u22b" > /etc/vconsole.conf

# пользователи
echo "$HOSTNAME" > /etc/hostname
echo "root:$ROOT_PASS" | chpasswd
useradd -mG wheel "$USERNAME"
echo "$USERNAME:$USER_PASS" | chpasswd
echo "%wheel ALL=(ALL:ALL) ALL" >> /etc/sudoers

# клонирование и копирование конфигов
su "$USERNAME" -c "cd && git clone --depth=1 https://git.postmodernist.ru/Rabbit/etc"
cd /home/"$USERNAME"/etc/early-conf
install -m 440 10-defaults /etc/sudoers.d/
install -m 644 mkinitcpio.conf /etc/
install -m 644 linux-zen.preset /etc/mkinitcpio.d/
install -m 644 pacman.conf /etc/
install -m 644 makepkg.conf /etc/
install -m 644 network/* /etc/systemd/network/
cd ..
rm -r early-conf
cd /

# правка makepkg.conf, если архитектура не raptorlake
if [ "$MARCH" != "raptorlake" ]; then
    sed -i "s/raptorlake/$MARCH/g" /etc/makepkg.conf
fi

# сеть
systemctl enable iwd systemd-networkd systemd-resolved
echo "WIRELESS_REGDOM=\"$REGDOM\"" > /etc/conf.d/wireless-regdom

# дополнительно
rm -f /boot/*.img
systemctl enable paccache.timer

# UKI
mkdir -p /boot/EFI/BOOT
if [ -f /boot/EFI/BOOT/BOOTX64.EFI ]; then
    mv /boot/EFI/BOOT/BOOTX64.EFI /boot/EFI/BOOT/bootx64_win.efi
    echo "Резервный загрузчик Windows переименован в bootx64_win.efi"
fi
echo "root=UUID=$(blkid -s UUID -o value "$ROOT") rw quiet splash" > /etc/kernel/cmdline
mkinitcpio -P

# удаляем скрипт после выполнения
rm /root/setup-chroot.sh
EOF

chmod +x /mnt/root/setup-chroot.sh

# ---------- запуск chroot ----------
arch-chroot /mnt env \
    HOSTNAME="$HOSTNAME" \
    USERNAME="$USERNAME" \
    ROOT_PASS="$ROOT_PASS" \
    USER_PASS="$USER_PASS" \
    ROOT="$ROOT" \
    REGDOM="$REGDOM" \
    TIMEZONE="$TIMEZONE" \
    LANG_FULL="$LANG_FULL" \
    MARCH="$MARCH" \
    /root/setup-chroot.sh

# ---------- пост-chroot действия ----------
read -p "Добавить запись в UEFI для Arch? (Нужно, если на раздел уже ссылается какая-то запись) [y/N]: " ADD_UEFI
if [[ "$ADD_UEFI" =~ ^[Yy]$ ]]; then
    DISK="/dev/$(lsblk -no PKNAME "$ESP")"
    PART_NUM=$(echo "$ESP" | grep -o '[0-9]*$')
    efibootmgr -c -d "$DISK" -p "$PART_NUM" -L "Arch Linux" -l /EFI/BOOT/BOOTX64.EFI -u
fi

# ------ замена resolv.conf на ссылку ------
ln -sf ../run/systemd/resolve/stub-resolv.conf /mnt/etc/resolv.conf

# ---------- размонтирование ----------
umount -R /mnt

echo
echo "=============================== Установка завершена ==============================="
echo "Перезагрузитесь (reboot) и запустите ~/etc/post-install.sh для завершения установки."
