#!/usr/bin/env bash
set -euo pipefail
# install_arch_caelestia.sh
# WARNING: script WILL WIPE DISK in DISK variable — check it!

### ====== CONFIG (edit carefully) ======
DISK="/dev/sda"                 # <--- проверь это
HOSTNAME="danilov-arch"
USERNAME="danilov"
TIMEZONE="Europe/Moscow"
LOCALE1="ru_RU.UTF-8"
LOCALE2="en_US.UTF-8"
KEYMAP="ru"
CPU_THREADS=14
PARALLEL_DOWNLOADS=10

# choices
USE_CHAOTIC="yes"
INSTALL_XANMOD="yes"
INSTALL_NVIDIA_DKMS="yes"

# Caelestia config target (where to clone)
CAELESTIA_QS_DIR="/home/${USERNAME}/.config/quickshell/caelestia"

### ====== Ask for passwords (interactive) ======
read -rsp "Root password (will be set later): " ROOT_PASS; echo
read -rsp "User '${USERNAME}' password (will be set later): " USER_PASS; echo

### ====== Basic checks ======
if [[ $EUID -ne 0 ]]; then
  echo "Запустите скрипт от root (sudo -i) и повторите."
  exit 1
fi

echo "Проверка сети..."
if ! ping -c3 archlinux.org &>/dev/null && ! ping -c3 8.8.8.8 &>/dev/null; then
  echo "Нет связи с сетью. Подключитесь (LAN) и повторите."
  exit 2
fi

### ====== Mirrorlist update ======
echo "[1/12] Установка reflector и обновление mirrorlist..."
pacman -Sy --noconfirm reflector || true
reflector --country "Russia,Poland,Germany,Netherlands" --latest 20 --sort rate --protocol https --save /etc/pacman.d/mirrorlist || true

### ====== Partitioning ======
echo "[2/12] Разметка диска: ${DISK}"
read -p "ВНИМАНИЕ: все данные на ${DISK} будут удалены. Если уверены — введите YES: " CONF
if [[ "$CONF" != "YES" ]]; then echo "Отменено."; exit 3; fi

# wipe and create GPT + EFI 512MiB + root ext4
sgdisk --zap-all "${DISK}"
parted -s "${DISK}" mklabel gpt
parted -s "${DISK}" mkpart ESP fat32 1MiB 513MiB
parted -s "${DISK}" set 1 boot on
parted -s "${DISK}" mkpart primary ext4 513MiB 100%

# partition names (nvme uses p1/p2)
if [[ "${DISK}" == *nvme* ]]; then
  EFI_PART="${DISK}p1"
  ROOT_PART="${DISK}p2"
else
  EFI_PART="${DISK}1"
  ROOT_PART="${DISK}2"
fi

echo "Форматирование разделов..."
mkfs.fat -F32 "${EFI_PART}"
mkfs.ext4 -F "${ROOT_PART}"

echo "Монтирование..."
mount "${ROOT_PART}" /mnt
mkdir -p /mnt/boot
mount "${EFI_PART}" /mnt/boot

### ====== Install base system ======
echo "[3/12] pacstrap base..."
pacstrap /mnt base base-devel linux linux-headers linux-firmware intel-ucode \
  vim git sudo networkmanager os-prober grub efibootmgr nano wget curl

genfstab -U /mnt > /mnt/etc/fstab

### ====== Prepare password file (inside /mnt root) ======
cat > /mnt/root/pwfile.txt <<EOF
root:${ROOT_PASS}
${USERNAME}:${USER_PASS}
EOF
chmod 600 /mnt/root/pwfile.txt

### ====== Create chroot post-install script (will run inside chroot) ======
cat > /mnt/root/chroot_post.sh <<'CHROOT'
#!/usr/bin/env bash
set -euo pipefail

# variables (expanded before chroot run)
HOSTNAME="__HOSTNAME__"
USERNAME="__USERNAME__"
TIMEZONE="__TIMEZONE__"
LOCALE1="__LOCALE1__"
LOCALE2="__LOCALE2__"
KEYMAP="__KEYMAP__"
CPU_THREADS="__CPU_THREADS__"
PARALLEL_DOWNLOADS="__PARALLEL_DOWNLOADS__"
USE_CHAOTIC="__USE_CHAOTIC__"
INSTALL_XANMOD="__INSTALL_XANMOD__"
INSTALL_NVIDIA_DKMS="__INSTALL_NVIDIA_DKMS__"
CAELESTIA_QS_DIR="__CAELESTIA_QS_DIR__"

export TERM=xterm

echo "[chroot] timezone & locale"
ln -sf /usr/share/zoneinfo/"${TIMEZONE}" /etc/localtime
hwclock --systohc

# locale
grep -q "^${LOCALE1} UTF-8" /etc/locale.gen || echo "${LOCALE1} UTF-8" >> /etc/locale.gen
grep -q "^${LOCALE2} UTF-8" /etc/locale.gen || echo "${LOCALE2} UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=${LOCALE1}" > /etc/locale.conf
echo "KEYMAP=${KEYMAP}" > /etc/vconsole.conf

# hostname + hosts
echo "${HOSTNAME}" > /etc/hostname
cat > /etc/hosts <<HOSTS
127.0.0.1	localhost
::1		localhost
127.0.1.1	${HOSTNAME}.localdomain ${HOSTNAME}
HOSTS

# create user & set passwords (read from /root/pwfile.txt)
groupadd -f audio || true
groupadd -f video || true
useradd -m -G wheel,audio,video,input,optical,storage -s /usr/bin/fish "${USERNAME}" || true
chmod 700 /home/"${USERNAME}"
# set passwords from file
if [ -f /root/pwfile.txt ]; then
  chpasswd < /root/pwfile.txt || true
  rm -f /root/pwfile.txt
fi
# allow wheel
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

# pacman tweaks
if ! grep -q "^ParallelDownloads" /etc/pacman.conf; then
  echo "ParallelDownloads = ${PARALLEL_DOWNLOADS}" >> /etc/pacman.conf
else
  sed -i "s/^ParallelDownloads.*/ParallelDownloads = ${PARALLEL_DOWNLOADS}/" /etc/pacman.conf
fi

# enable multilib
if ! grep -q "^\[multilib\]" /etc/pacman.conf; then
  cat >> /etc/pacman.conf <<MULTILIB
[multilib]
Include = /etc/pacman.d/mirrorlist
MULTILIB
fi

# set MAKEFLAGS
cp /etc/makepkg.conf /etc/makepkg.conf.bak || true
if grep -q '^#MAKEFLAGS' /etc/makepkg.conf; then
  sed -i "s|^#MAKEFLAGS=.*|MAKEFLAGS=\"-j${CPU_THREADS}\"|" /etc/makepkg.conf
elif grep -q '^MAKEFLAGS' /etc/makepkg.conf; then
  sed -i "s|^MAKEFLAGS=.*|MAKEFLAGS=\"-j${CPU_THREADS}\"|" /etc/makepkg.conf
else
  echo "MAKEFLAGS=\"-j${CPU_THREADS}\"" >> /etc/makepkg.conf
fi

# update system DB
pacman -Syyu --noconfirm

### === Chaotic (optional) ===
if [ "${USE_CHAOTIC}" = "yes" ]; then
  echo "[chroot] adding Chaotic-AUR repo..."
  # import key (try multiple keyservers)
  pacman-key --recv-keys 3056513887B78AEB --keyserver keyserver.ubuntu.com || true
  pacman-key --recv-keys 3056513887B78AEB --keyserver hkps://keys.openpgp.org || true
  pacman-key --lsign-key 3056513887B78AEB || true
  pacman -U --noconfirm "https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-keyring.pkg.tar.zst" "https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-mirrorlist.pkg.tar.zst" || true
  if ! grep -q "^\[chaotic-aur\]" /etc/pacman.conf; then
    cat >> /etc/pacman.conf <<'CHAOTIC'
[chaotic-aur]
Include = /etc/pacman.d/chaotic-mirrorlist
CHAOTIC
  fi
  pacman -Syyu --noconfirm
fi

# install essentials & dev tools
pacman -S --noconfirm --needed git base-devel

# install paru (build as user)
echo "[chroot] building paru as user ${USERNAME}..."
runuser -u "${USERNAME}" -- bash -lc 'cd ~ && git clone https://aur.archlinux.org/paru.git 2>/dev/null || true && cd paru && makepkg -si --noconfirm || true'

# kernel: install linux-xanmod (if requested)
if [ "${INSTALL_XANMOD}" = "yes" ]; then
  echo "[chroot] installing linux-xanmod..."
  pacman -S --noconfirm --needed linux-xanmod linux-xanmod-headers || true
fi

# NVIDIA DKMS
if [ "${INSTALL_NVIDIA_DKMS}" = "yes" ]; then
  echo "[chroot] installing nvidia-dkms and 32-bit libs..."
  pacman -S --noconfirm --needed dkms nvidia-dkms nvidia-utils lib32-nvidia-utils || true
  pacman -S --noconfirm --needed vulkan-icd-loader lib32-vulkan-icd-loader vulkan-tools || true
fi

# enable multilib packages for gaming
pacman -S --noconfirm --needed steam steam-native-runtime lutris wine winetricks lib32-alsa-plugins lib32-libpulse gamemode mangohud lib32-mesa || true

# use paru (as user) to install AUR gaming helpers (protonup, dxvk, vkd3d)
echo "[chroot] installing AUR gaming helpers..."
runuser -u "${USERNAME}" -- bash -lc 'paru -S --noconfirm protonup-qt dxvk-bin vkd3d-proton lib32-vkd3d-proton || true'

# Hyprland + system utilities
pacman -S --noconfirm --needed hyprland wayland-protocols wlroots xorg-xwayland xdg-desktop-portal xdg-desktop-portal-hyprland \
  pipewire pipewire-alsa pipewire-pulse wireplumber wireplumber-media-session wireplumber-alsa xdg-desktop-portal-gtk \
  grim swappy slurp wl-clipboard wl-screenrec lm_sensors ddcutil brightnessctl app2unit cava awk libqalculate fish neofetch btop kitty || true

# fonts (community/AUR combos) - use paru for some fonts
pacman -S --noconfirm --needed ttf-jetbrains-mono-nerd || true
runuser -u "${USERNAME}" -- bash -lc 'paru -S --noconfirm ttf-material-symbols-variable-git || true'

# Quickshell + Caelestia (AUR + manual)
echo "[chroot] installing quickshell (AUR) and related AUR packages..."
runuser -u "${USERNAME}" -- bash -lc 'paru -S --noconfirm quickshell-git caelestia-shell-git caelestia-cli-git app2unit-git ddcutil brightnessctl cava aubio swappy grim libqalculate || true'

# ensure quickshell config dir exists and clone caelestia repo manually (preferred for exact config)
mkdir -p /home/"${USERNAME}"/.config/quickshell
chown -R "${USERNAME}:${USERNAME}" /home/"${USERNAME}"/.config
runuser -u "${USERNAME}" -- bash -lc 'cd ~/.config/quickshell && git clone https://github.com/caelestia-dots/shell.git caelestia || (cd caelestia && git pull) || true'
chown -R "${USERNAME}:${USERNAME}" /home/"${USERNAME}"/.config/quickshell/caelestia

# build beat_detector as regular user (requires aubio & pipewire headers)
mkdir -p /usr/lib/caelestia
chown root:root /usr/lib/caelestia
runuser -u "${USERNAME}" -- bash -lc 'cd ~/.config/quickshell/caelestia && g++ -std=c++17 -Wall -Wextra -I/usr/include/pipewire-0.3 -I/usr/include/spa-0.2 -I/usr/include/aubio -o beat_detector assets/beat_detector.cpp -lpipewire-0.3 -laubio || true'
if [ -f /home/"${USERNAME}"/.config/quickshell/caelestia/beat_detector ]; then
  mv /home/"${USERNAME}"/.config/quickshell/caelestia/beat_detector /usr/lib/caelestia/beat_detector || true
  chmod 755 /usr/lib/caelestia/beat_detector || true
fi

# install caelestia config into ~/.config/caelestia
mkdir -p /home/"${USERNAME}"/.config/caelestia
cp -r /home/"${USERNAME}"/.config/quickshell/caelestia/config/* /home/"${USERNAME}"/.config/caelestia/ 2>/dev/null || true
chown -R "${USERNAME}:${USERNAME}" /home/"${USERNAME}"/.config/caelestia /home/"${USERNAME}"/.config/quickshell/caelestia

# hyprland user config: autostart caelestia via quickshell
mkdir -p /home/"${USERNAME}"/.config/hypr
cat > /home/"${USERNAME}"/.config/hypr/hyprland.conf <<HYPR
# minimal hypr config - will likely be extended by caelestia config
exec-once = qs -c caelestia
HYPR
chown -R "${USERNAME}:${USERNAME}" /home/"${USERNAME}"/.config/hypr

# create autologin on tty1 and autostart Hyprland for that user
cat > /etc/systemd/system/getty@tty1.service.d/override.conf <<GETTY
[Service]
ExecStart=
ExecStart=-/usr/bin/agetty --autologin ${USERNAME} --noclear %I \$TERM
Type=idle
GETTY

# create user shell profile to exec Hyprland on tty1
cat > /home/"${USERNAME}"/.profile <<'PROFILE'
# autostart Hyprland on tty1
if [ -z "$DISPLAY" ] && [ "$(tty)" = "/dev/tty1" ]; then
  exec dbus-run-session -- Hyprland
fi
PROFILE
chown "${USERNAME}:${USERNAME}" /home/"${USERNAME}"/.profile
chmod 644 /home/"${USERNAME}"/.profile

# makefish default shell (if fish installed)
if command -v fish >/dev/null 2>&1; then
  chsh -s /usr/bin/fish "${USERNAME}" || true
fi

# enable services
systemctl enable NetworkManager || true
systemctl enable --now getty@tty1.service || true

# pipewire services are usually user services; enabling system-level for safety:
systemctl enable --now pipewire.service pipewire-pulse.service wireplumber.service || true

# initramfs & grub
mkinitcpio -P || true
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB || true
grub-mkconfig -o /boot/grub/grub.cfg || true

echo "[chroot] finished. Reboot after exiting chroot."
CHROOT

# fill placeholders into chroot_post.sh
sed -i "s|__HOSTNAME__|${HOSTNAME}|g" /mnt/root/chroot_post.sh
sed -i "s|__USERNAME__|${USERNAME}|g" /mnt/root/chroot_post.sh
sed -i "s|__TIMEZONE__|${TIMEZONE}|g" /mnt/root/chroot_post.sh
sed -i "s|__LOCALE1__|${LOCALE1}|g" /mnt/root/chroot_post.sh
sed -i "s|__LOCALE2__|${LOCALE2}|g" /mnt/root/chroot_post.sh
sed -i "s|__KEYMAP__|${KEYMAP}|g" /mnt/root/chroot_post.sh
sed -i "s|__CPU_THREADS__|${CPU_THREADS}|g" /mnt/root/chroot_post.sh
sed -i "s|__PARALLEL_DOWNLOADS__|${PARALLEL_DOWNLOADS}|g" /mnt/root/chroot_post.sh
sed -i "s|__USE_CHAOTIC__|${USE_CHAOTIC}|g" /mnt/root/chroot_post.sh
sed -i "s|__INSTALL_XANMOD__|${INSTALL_XANMOD}|g" /mnt/root/chroot_post.sh
sed -i "s|__INSTALL_NVIDIA_DKMS__|${INSTALL_NVIDIA_DKMS}|g" /mnt/root/chroot_post.sh
sed -i "s|__CAELESTIA_QS_DIR__|${CAELESTIA_QS_DIR}|g" /mnt/root/chroot_post.sh

# make executable and run in chroot
chmod +x /mnt/root/chroot_post.sh
arch-chroot /mnt /root/chroot_post.sh

# cleanup
rm -f /mnt/root/chroot_post.sh /mnt/root/pwfile.txt

echo "=== Установка завершена. Отмонтируем и перезагрузимся ==="
umount -R /mnt || true
echo "Готово. Введите: reboot"
