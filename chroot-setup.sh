#!/bin/bash
set -euo pipefail

TIMEZONE=$1
LANG_CHOICE=$2
TARGET_HOST=$3
USERNAME=$4
WAIT_ONLINE_ANY=$5
SETUP_INTEL=$6
REGDOM=$7
ROOT_PASS=$8
USER_PASS=$9

# время
ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
hwclock --systohc

# локаль
sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
[[ "$LANG_CHOICE" != "en_US.UTF-8" ]] && sed -i "s/^#${LANG_CHOICE//./\\.} UTF-8/${LANG_CHOICE} UTF-8/" /etc/locale.gen
locale-gen
printf 'LANG=%s\n' "$LANG_CHOICE" >/etc/locale.conf
printf 'KEYMAP=ruwin_alt_sh-UTF-8\nFONT=ter-u22b\n' >/etc/vconsole.conf

# пользователи
printf '%s\n' "$TARGET_HOST" >/etc/hostname
useradd -mG wheel "$USERNAME"
printf 'root:%s\n%s:%s\n' "$ROOT_PASS" "$USERNAME" "$USER_PASS" | chpasswd
passwd -l root
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

# конфиги
su "$USERNAME" -c 'cd && git clone --depth=1 https://git.postmodernist.ru/Rabbit/etc'
(
  cd "/home/$USERNAME/etc/early-conf"
  install -Dm440 10-defaults /etc/sudoers.d/
  install -Dm644 mkinitcpio.conf /etc/
  install -Dm644 vtrgb /etc/vtrgb
  install -Dm644 vconsole-override.conf /etc/systemd/system/systemd-vconsole-setup.service.d/override.conf
  install -Dm644 linux-zen.preset /etc/mkinitcpio.d/
  install -Dm644 pacman.conf /etc/
  install -Dm644 makepkg.conf /etc/
  install -Dm644 env.sh /etc/profile.d/
  install -Dm644 network/*.network /etc/systemd/network/
  if [[ ! "$WAIT_ONLINE_ANY" =~ ^[Nn]$ ]]; then
    install -Dm644 network/override.conf \
      /etc/systemd/system/systemd-networkd-wait-online.service.d/override.conf
  fi
  if [[ ! "$SETUP_INTEL" =~ ^[Nn]$ ]]; then
    install -Dm644 intel-undervolt.conf /etc/
    systemctl enable intel-undervolt.service
  fi
  tar --zstd --no-same-owner -xf glow-slide.tar.zst -C /usr/share/plymouth/themes
  plymouth-set-default-theme glow-slide
)

# сеть
systemctl enable iwd systemd-networkd systemd-resolved
sed -i "s/^#WIRELESS_REGDOM=\"$REGDOM\"/WIRELESS_REGDOM=\"$REGDOM\"/" /etc/conf.d/wireless-regdom

# прочее
rm -f /boot/*.img
systemctl enable paccache.timer linux-modules-cleanup.service gpm
sed -i 's/^.*RebootWatchdogSec=.*/RebootWatchdogSec=0/' /etc/systemd/system.conf
sed -i 's/^.*set bell-style none/set bell-style none/' /etc/inputrc

# UKI
mkinitcpio -P
