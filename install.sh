#!/usr/bin/env bash
set -euo pipefail
# install_arch_caelestia.sh - improved, safer version

### ===== CONFIG - проверь перед запуском =====
DISK="/dev/sda"                    # <--- проверь!
HOSTNAME="danilov-arch"
USERNAME="danilov"
TIMEZONE="Europe/Moscow"
LOCALE1="ru_RU.UTF-8"
LOCALE2="en_US.UTF-8"
KEYMAP="ru"
CPU_THREADS=14
PARALLEL_DOWNLOADS=12              # 10-14 нормально; я поставил 12 как баланс
MAKEFLAGS_JOBS="$CPU_THREADS"

USE_CHAOTIC="yes"
INSTALL_XANMOD="yes"
INSTALL_NVIDIA_DKMS="yes"

CAELESTIA_QS_DIR="/home/${USERNAME}/.config/quickshell/caelestia"

### ===== read passwords interactively (will be written to /mnt/root/pwfile.txt) =====
read -rsp "Root password: " ROOT_PASS; echo
read -rsp "User ${USERNAME} password: " USER_PASS; echo

if [[ $EUID -ne 0 ]]; then
  echo "Запустите скрипт от root." >&2
  exit 1
fi

# network check
if ! ping -c3 -W 2 8.8.8.8 &>/dev/null && ! ping -c3 -W 2 archlinux.org &>/dev/null; then
  echo "Нет сети. Подключитесь по LAN и повторите."
  exit 2
fi

echo "[0] Устанавливаем оптимизацию pacman на live (ParallelDownloads=${PARALLEL_DOWNLOADS})"
# set ParallelDownloads in the live system pacman.conf so pacstrap uses it
if ! grep -q "^ParallelDownloads" /etc/pacman.conf 2>/dev/null; then
  echo "ParallelDownloads = ${PARALLEL_DOWNLOADS}" >> /etc/pacman.conf
else
  sed -i "s/^ParallelDownloads.*/ParallelDownloads = ${PARALLEL_DOWNLOADS}/" /etc/pacman.conf
fi

echo "[1] Обновляем mirrorlist (reflector)"
pacman -Sy --noconfirm reflector || true
reflector --country "Russia,Poland,Germany,Netherlands" --latest 20 --sort rate --protocol https --save /etc/pacman.d/mirrorlist || true

echo "[2] Разметка диска ${DISK} (GPT, EFI 512MiB, root ext4)"
read -p "ВНИМАНИЕ: Это удалит все данные на ${DISK}. Если согласен, введи YES: " CONF
if [[ "$CONF" != "YES" ]]; then echo "Отмена."; exit 1; fi

sgdisk --zap-all "${DISK}"
parted -s "${DISK}" mklabel gpt
parted -s "${DISK}" mkpart ESP fat32 1MiB 513MiB
parted -s "${DISK}" set 1 boot on
parted -s "${DISK}" mkpart primary ext4 513MiB 100%

# partition names (nvme -> p1/p2)
if [[ "${DISK}" == *nvme* ]]; then
  EFI_PART="${DISK}p1"
  ROOT_PART="${DISK}p2"
else
  EFI_PART="${DISK}1"
  ROOT_PART="${DISK}2"
fi

mkfs.fat -F32 "${EFI_PART}"
mkfs.ext4 -F "${ROOT_PART}"

mount "${ROOT_PART}" /mnt
mkdir -p /mnt/boot
mount "${EFI_PART}" /mnt/boot

echo "[3] pacstrap base system (linux vanilla now, later xanmod will be installed)"
pacstrap /mnt base base-devel linux linux-headers linux-firmware intel-ucode \
  vim git sudo networkmanager os-prober grub efibootmgr nano wget curl

genfstab -U /mnt >> /mnt/etc/fstab

# write pwfile to set passwords inside chroot securely
cat > /mnt/root/pwfile.txt <<EOF
root:${ROOT_PASS}
${USERNAME}:${USER_PASS}
EOF
chmod 600 /mnt/root/pwfile.txt

### Build the chroot-post script with variables expanded (safer than complex placeholder perl)
cat > /mnt/root/chroot_post.sh <<CHROOT
#!/usr/bin/env bash
set -euo pipefail

HOSTNAME="${HOSTNAME}"
USERNAME="${USERNAME}"
TIMEZONE="${TIMEZONE}"
LOCALE1="${LOCALE1}"
LOCALE2="${LOCALE2}"
KEYMAP="${KEYMAP}"
CPU_THREADS="${CPU_THREADS}"
PARALLEL_DOWNLOADS="${PARALLEL_DOWNLOADS}"
MAKEFLAGS_JOBS="${MAKEFLAGS_JOBS}"
USE_CHAOTIC="${USE_CHAOTIC}"
INSTALL_XANMOD="${INSTALL_XANMOD}"
INSTALL_NVIDIA_DKMS="${INSTALL_NVIDIA_DKMS}"
CAELESTIA_QS_DIR="${CAELESTIA_QS_DIR}"

export TERM=xterm

echo "[chroot] timezone & locale"
ln -sf /usr/share/zoneinfo/\${TIMEZONE} /etc/localtime
hwclock --systohc

# locales
grep -q "^\${LOCALE1} UTF-8" /etc/locale.gen || echo "\${LOCALE1} UTF-8" >> /etc/locale.gen
grep -q "^\${LOCALE2} UTF-8" /etc/locale.gen || echo "\${LOCALE2} UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=\${LOCALE1}" > /etc/locale.conf
echo "KEYMAP=\${KEYMAP}" > /etc/vconsole.conf

# hostname
echo "\${HOSTNAME}" > /etc/hostname
cat > /etc/hosts <<HOSTS
127.0.0.1	localhost
::1		localhost
127.0.1.1	\${HOSTNAME}.localdomain \${HOSTNAME}
HOSTS

# create user and set passwords from /root/pwfile.txt
groupadd -f audio || true
groupadd -f video || true
useradd -m -G wheel,audio,video,input,optical,storage -s /bin/bash "\${USERNAME}" || true
if [ -f /root/pwfile.txt ]; then
  chpasswd < /root/pwfile.txt || true
  rm -f /root/pwfile.txt
fi
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers || true

# pacman tweaks (inside chroot additionally)
if ! grep -q "^ParallelDownloads" /etc/pacman.conf 2>/dev/null; then
  echo "ParallelDownloads = \${PARALLEL_DOWNLOADS}" >> /etc/pacman.conf
else
  sed -i "s/^ParallelDownloads.*/ParallelDownloads = \${PARALLEL_DOWNLOADS}/" /etc/pacman.conf
fi

# enable multilib
if ! grep -q "^\[multilib\]" /etc/pacman.conf; then
  cat >> /etc/pacman.conf <<MULTILIB
[multilib]
Include = /etc/pacman.d/mirrorlist
MULTILIB
fi

# set MAKEFLAGS for makepkg
cp /etc/makepkg.conf /etc/makepkg.conf.bak || true
if grep -q '^#MAKEFLAGS' /etc/makepkg.conf; then
  sed -i "s|^#MAKEFLAGS=.*|MAKEFLAGS=\"-j\${MAKEFLAGS_JOBS}\"|" /etc/makepkg.conf
else
  sed -i "s|^MAKEFLAGS=.*|MAKEFLAGS=\"-j\${MAKEFLAGS_JOBS}\"|" /etc/makepkg.conf || echo "MAKEFLAGS=\"-j\${MAKEFLAGS_JOBS}\"" >> /etc/makepkg.conf
fi

pacman -Syyu --noconfirm

# Chaotic
if [ "\${USE_CHAOTIC}" = "yes" ]; then
  echo "[chroot] adding Chaotic-AUR..."
  pacman-key --recv-keys 3056513887B78AEB --keyserver keyserver.ubuntu.com || pacman-key --recv-keys 3056513887B78AEB --keyserver hkps://keys.openpgp.org || true
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

# essentials
pacman -S --noconfirm --needed git base-devel

# build paru as user (safer than root)
echo "[chroot] building paru as user \${USERNAME}..."
runuser -u "\${USERNAME}" -- bash -lc 'cd ~ && git clone https://aur.archlinux.org/paru.git 2>/dev/null || true && cd paru && makepkg -si --noconfirm || true'

# install xanmod (if requested) BEFORE nvidia-dkms to avoid mismatched modules
if [ "\${INSTALL_XANMOD}" = "yes" ]; then
  pacman -S --noconfirm --needed linux-xanmod linux-xanmod-headers || true
fi

# NVIDIA DKMS and Vulkan (recommended for custom kernels)
if [ "\${INSTALL_NVIDIA_DKMS}" = "yes" ]; then
  pacman -S --noconfirm --needed dkms nvidia-dkms nvidia-utils lib32-nvidia-utils || true
  pacman -S --noconfirm --needed vulkan-icd-loader lib32-vulkan-icd-loader vulkan-tools || true
fi

# gaming stack (official + AUR)
pacman -S --noconfirm --needed steam steam-native-runtime lutris wine winetricks lib32-alsa-plugins lib32-libpulse gamemode mangohud lib32-mesa || true
runuser -u "\${USERNAME}" -- bash -lc 'paru -S --noconfirm protonup-qt dxvk-bin vkd3d-proton lib32-vkd3d-proton || true'

# hyprland + pipewire + utilities
pacman -S --noconfirm --needed hyprland wayland-protocols wlroots xorg-xwayland \
  xdg-desktop-portal xdg-desktop-portal-gtk pipewire pipewire-alsa pipewire-pulse wireplumber \
  kitty cava cmatrix neofetch fastfetch btop grim swappy lm_sensors libqalculate fish || true

# Try to install xdg-desktop-portal-hyprland via paru if available (better portal integration)
runuser -u "\${USERNAME}" -- bash -lc 'paru -S --noconfirm xdg-desktop-portal-hyprland || true'

# fonts
pacman -S --noconfirm --needed ttf-jetbrains-mono-nerd || true
runuser -u "\${USERNAME}" -- bash -lc 'paru -S --noconfirm ttf-material-symbols-variable-git || true'

# quickshell + caelestia (install via AUR where possible, else manual clone)
runuser -u "\${USERNAME}" -- bash -lc 'paru -S --noconfirm quickshell-git caelestia-shell-git caelestia-cli-git app2unit-git ddcutil brightnessctl cava aubio swappy grim libqalculate || true'

# ensure config dir exists and clone caelestia repo (manual) to get exact files
runuser -u "\${USERNAME}" -- bash -lc 'mkdir -p ~/.config/quickshell && cd ~/.config/quickshell && git clone https://github.com/caelestia-dots/shell.git caelestia 2>/dev/null || (cd caelestia && git pull) || true'

# build beat_detector (as user)
runuser -u "\${USERNAME}" -- bash -lc 'cd ~/.config/quickshell/caelestia && g++ -std=c++17 -Wall -Wextra -I/usr/include/pipewire-0.3 -I/usr/include/spa-0.2 -I/usr/include/aubio -o beat_detector assets/beat_detector.cpp -lpipewire-0.3 -laubio || true'
if [ -f /home/"\${USERNAME}"/.config/quickshell/caelestia/beat_detector ]; then
  mv /home/"\${USERNAME}"/.config/quickshell/caelestia/beat_detector /usr/lib/caelestia/beat_detector || true
  chmod 755 /usr/lib/caelestia/beat_detector || true
fi

# copy example configs into ~/.config/caelestia if present
mkdir -p /home/"\${USERNAME}"/.config/caelestia
cp -r /home/"\${USERNAME}"/.config/quickshell/caelestia/config/* /home/"\${USERNAME}"/.config/caelestia/ 2>/dev/null || true
chown -R "\${USERNAME}:\${USERNAME}" /home/"\${USERNAME}"/.config/quickshell /home/"\${USERNAME}"/.config/caelestia || true

# minimal hypr config autostart
mkdir -p /home/"\${USERNAME}"/.config/hypr
cat > /home/"\${USERNAME}"/.config/hypr/hyprland.conf <<HYPR
exec-once = qs -c caelestia
HYPR
chown -R "\${USERNAME}:\${USERNAME}" /home/"\${USERNAME}"/.config/hypr

# autologin tty1 + auto-start hyprland on tty1
mkdir -p /etc/systemd/system/getty@tty1.service.d
cat > /etc/systemd/system/getty@tty1.service.d/override.conf <<GETTY
[Service]
ExecStart=
ExecStart=-/usr/bin/agetty --autologin ${USERNAME} --noclear %I \$TERM
Type=idle
GETTY

cat > /home/"\${USERNAME}"/.profile <<'PROFILE'
# autostart Hyprland on tty1
if [ -z "$DISPLAY" ] && [ "$(tty)" = "/dev/tty1" ]; then
  exec dbus-run-session -- Hyprland
fi
PROFILE
chown "\${USERNAME}:\${USERNAME}" /home/"\${USERNAME}"/.profile
chmod 644 /home/"\${USERNAME}"/.profile

# set default shell to fish (optional)
if command -v fish >/dev/null 2>&1; then
  chsh -s /usr/bin/fish "\${USERNAME}" || true
fi

# enable services
systemctl enable NetworkManager || true
systemctl enable --now getty@tty1.service || true
systemctl enable --now pipewire.service pipewire-pulse.service wireplumber.service || true

# initramfs and grub
mkinitcpio -P || true
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB || true
grub-mkconfig -o /boot/grub/grub.cfg || true

echo "[chroot] finished"
CHROOT

# make executable and run in chroot
chmod +x /mnt/root/chroot_post.sh
arch-chroot /mnt /root/chroot_post.sh

# cleanup
rm -f /mnt/root/chroot_post.sh /mnt/root/pwfile.txt

echo "Установка завершена. Отмонтируем /mnt и перезагрузимся."
umount -R /mnt || true
echo "Готово — введи 'reboot' для перезагрузки."
