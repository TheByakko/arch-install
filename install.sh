#!/usr/bin/env bash
set -euo pipefail
# arch_install_caelestia.sh
# WARNING: this script WILL WIPE DISK specified in DISK variable.
# Read the script before running.

### === CONFIG — редактируй аккуратно перед запуском === ###
DISK="/dev/sda"                    # целевой диск — убедись!
HOSTNAME="danilov-arch"
USERNAME="danilov"
TIMEZONE="Europe/Moscow"
LOCALE1="ru_RU.UTF-8"
LOCALE2="en_US.UTF-8"
KEYMAP="ru"
CPU_THREADS=14
PARALLEL_DOWNLOADS=10
MAKEFLAGS_JOBS="$CPU_THREADS"

# AUR / Chaotic choices
USE_CHAOTIC="yes"                  # yes = подключаем Chaotic (по запросу)
INSTALL_XANMOD="yes"               # ставим linux-xanmod из Chaotic
INSTALL_NVIDIA_DKMS="yes"          # nvidia-dkms (рекомендуется для кастомного ядра)

# Where to clone Caelestia
CAELESTIA_TARGET_DIR="/home/${USERNAME}/.config/quickshell/caelestia"

### === Ввод паролей интерактивно (в начале) === ###
read -rsp "Root password (will be set non-interactively): " ROOT_PASS
echo
read -rsp "User (${USERNAME}) password (will be set non-interactively): " USER_PASS
echo

echo "=== Проверяем, что вы root ==="
if [[ $EUID -ne 0 ]]; then
  echo "Запустите скрипт от root." >&2
  exit 1
fi

echo "=== 1) Проверка интернета..."
if ! ping -c3 8.8.8.8 &>/dev/null; then
  echo "Проверка сети не пройдена. Подключитесь к сети и повторите." >&2
  exit 2
fi

echo "=== 2) Обновление mirrorlist (reflector)..."
pacman -Sy --noconfirm reflector || true
reflector --country "Russia,Poland,Germany,Netherlands" --latest 20 --sort rate --protocol https --save /etc/pacman.d/mirrorlist || true

echo "=== 3) Разметка диска: ${DISK} (GPT, EFI, ext4) ==="
read -p "ВНИМАНИЕ: Это удалит все данные на ${DISK}. Продолжить? [type YES] " CONF
if [[ "$CONF" != "YES" ]]; then
  echo "Отменено."
  exit 3
fi

# Удаляем старую табл. разделов и создаём 2 раздела: EFI 512MiB и root ext4
sgdisk --zap-all "${DISK}"
parted -s "${DISK}" mklabel gpt
parted -s "${DISK}" mkpart ESP fat32 1MiB 513MiB
parted -s "${DISK}" set 1 boot on
parted -s "${DISK}" mkpart primary ext4 513MiB 100%

# строим имена устройств (поддержка nvme: /dev/nvme0n1p1)
EFI_PART="${DISK}1"
ROOT_PART="${DISK}2"

echo "mkfs..."
mkfs.fat -F32 "${EFI_PART}"
mkfs.ext4 -F "${ROOT_PART}"

echo "монтирование..."
mount "${ROOT_PART}" /mnt
mkdir -p /mnt/boot
mount "${EFI_PART}" /mnt/boot

echo "=== 4) Установка базовой системы (pacstrap) ==="
pacstrap /mnt base base-devel linux linux-headers linux-firmware intel-ucode \
  vim git sudo networkmanager os-prober grub efibootmgr nano wget curl

genfstab -U /mnt >> /mnt/etc/fstab

### === 5) Входим в chroot и продолжаем автоматические шаги === ###
arch-chroot /mnt /bin/bash <<'CHROOT_EOF'
set -euo pipefail
# внутри chroot: используем внешние переменные, поэтому считываем их via env file from /proc (we'll get them from the caller using heredoc)
CHROOT_EOF

# Чтобы передать переменные в chroot — создадим временный скрипт и запустим его в chroot
cat > /mnt/root/chroot_post.sh <<'CHROOT_SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

# Внутри chroot — используем переменные, переданные через environment file:
DISK="${DISK_PLACEHOLDER}"
HOSTNAME="${HOSTNAME_PLACEHOLDER}"
USERNAME="${USERNAME_PLACEHOLDER}"
TIMEZONE="${TIMEZONE_PLACEHOLDER}"
LOCALE1="${LOCALE1_PLACEHOLDER}"
LOCALE2="${LOCALE2_PLACEHOLDER}"
KEYMAP="${KEYMAP_PLACEHOLDER}"
CPU_THREADS="${CPU_THREADS_PLACEHOLDER}"
PARALLEL_DOWNLOADS="${PARALLEL_DOWNLOADS_PLACEHOLDER}"
MAKEFLAGS_JOBS="${MAKEFLAGS_JOBS_PLACEHOLDER}"
USE_CHAOTIC="${USE_CHAOTIC_PLACEHOLDER}"
INSTALL_XANMOD="${INSTALL_XANMOD_PLACEHOLDER}"
INSTALL_NVIDIA_DKMS="${INSTALL_NVIDIA_DKMS_PLACEHOLDER}"
CAELESTIA_TARGET_DIR="${CAELESTIA_TARGET_DIR_PLACEHOLDER}"
ROOT_PASS="${ROOT_PASS_PLACEHOLDER}"
USER_PASS="${USER_PASS_PLACEHOLDER}"

echo "=== chroot: timezone & locale ==="
ln -sf /usr/share/zoneinfo/"${TIMEZONE}" /etc/localtime
hwclock --systohc

# локали
sed -i "s/^#\(${LOCALE1} UTF-8\)/\1/" /etc/locale.gen || true
sed -i "s/^#\(${LOCALE2} UTF-8\)/\1/" /etc/locale.gen || true
locale-gen
echo "LANG=${LOCALE1}" > /etc/locale.conf
echo "KEYMAP=${KEYMAP}" > /etc/vconsole.conf

# hostname
echo "${HOSTNAME}" > /etc/hostname
cat > /etc/hosts <<EOF
127.0.0.1	localhost
::1		localhost
127.0.1.1	${HOSTNAME}.localdomain ${HOSTNAME}
EOF

# пароли (установим из переданных переменных)
echo "root:${ROOT_PASS}" | chpasswd
useradd -m -G wheel -s /bin/bash "${USERNAME}" || true
echo "${USERNAME}:${USER_PASS}" | chpasswd
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers || true

# ускоряем pacman: ParallelDownloads и multilib
echo "=== Настройка pacman.conf (ParallelDownloads=${PARALLEL_DOWNLOADS}) и multilib ==="
if ! grep -q "^ParallelDownloads" /etc/pacman.conf; then
  echo "ParallelDownloads = ${PARALLEL_DOWNLOADS}" >> /etc/pacman.conf
else
  sed -i "s/^ParallelDownloads.*/ParallelDownloads = ${PARALLEL_DOWNLOADS}/" /etc/pacman.conf
fi

if ! grep -q "^\[multilib\]" /etc/pacman.conf; then
  cat >> /etc/pacman.conf <<'MULTILIB'
[multilib]
Include = /etc/pacman.d/mirrorlist
MULTILIB
fi

# MAKEFLAGS для makepkg
cp /etc/makepkg.conf /etc/makepkg.conf.bak || true
if grep -q '^#MAKEFLAGS' /etc/makepkg.conf; then
  sed -i "s|^#MAKEFLAGS=.*|MAKEFLAGS=\"-j${MAKEFLAGS_JOBS}\"|" /etc/makepkg.conf
elif grep -q '^MAKEFLAGS' /etc/makepkg.conf; then
  sed -i "s|^MAKEFLAGS=.*|MAKEFLAGS=\"-j${MAKEFLAGS_JOBS}\"|" /etc/makepkg.conf
else
  echo "MAKEFLAGS=\"-j${MAKEFLAGS_JOBS}\"" >> /etc/makepkg.conf
fi

# обновим базы
pacman -Syyu --noconfirm

# === Chaotic-AUR (если включено) ===
if [ "${USE_CHAOTIC}" = "yes" ]; then
  echo "=== Подключаем Chaotic-AUR ==="
  pacman-key --recv-key 3056513887B78AEB --keyserver keyserver.ubuntu.com || true
  pacman-key --lsign-key 3056513887B78AEB || true
  pacman -U --noconfirm 'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-keyring.pkg.tar.zst' 'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-mirrorlist.pkg.tar.zst' || true
  if ! grep -q "^\[chaotic-aur\]" /etc/pacman.conf; then
    cat >> /etc/pacman.conf <<'CHAOTIC'
[chaotic-aur]
Include = /etc/pacman.d/chaotic-mirrorlist
CHAOTIC
  fi
  pacman -Syyu --noconfirm
fi

# === Установка paru (AUR helper) ===
echo "=== Установка paru (AUR helper) ==="
pacman -S --needed --noconfirm git base-devel
cd /tmp
if ! command -v paru &>/dev/null; then
  git clone https://aur.archlinux.org/paru.git || true
  cd paru
  makepkg -si --noconfirm || true
fi
cd /

# === Ядро linux-xanmod и NVIDIA DKMS: СТАВИМ СНАЧАЛА XANMOD, ПОТОМ NVIDIA DKMS ===
if [ "${INSTALL_XANMOD}" = "yes" ]; then
  echo "=== Установка linux-xanmod из Chaotic/AUR ==="
  pacman -S --noconfirm linux-xanmod linux-xanmod-headers || true
fi

if [ "${INSTALL_NVIDIA_DKMS}" = "yes" ]; then
  echo "=== Установка nvidia-dkms (рекомендуется) и 32-bit libs ==="
  pacman -S --noconfirm nvidia-dkms nvidia-utils lib32-nvidia-utils
  # Vulkan support for Nvidia
  pacman -S --noconfirm vulkan-icd-loader lib32-vulkan-icd-loader vulkan-tools
fi

# === Базовый игровой стек ===
echo "=== Установка игрового стека (steam, wine, lutris, mangohud, gamemode) ==="
pacman -S --noconfirm steam lutris wine winetricks lib32-alsa-plugins lib32-libpulse gamemode mangohud lib32-mesa || true
# Proton / DXVK / vkd3d (AUR)
paru -S --noconfirm protonup-qt dxvk-bin vkd3d-proton lib32-vkd3d-proton || true

# === Hyprland + utilities ===
echo "=== Установка Hyprland + утилит ==="
pacman -S --noconfirm hyprland wayland-protocols wlroots xorg-xwayland xdg-desktop-portal-gtk qt6-declarative \
  pipewire pipewire-pulse pipewire-alsa pipewire-jack pamixer pavucontrol \
  kitty cava cmatrix neofetch fastfetch btop grim swappy lm_sensors libqalculate || true

# Fonts and extra deps
paru -S --noconfirm ttf-material-symbols-variable-git ttf-jetbrains-mono-nerd || true

# === Quickshell + Caelestia (AUR or manual) ===
echo "=== Установка Quickshell (AUR) и Caelestia (клонируем конфиг и собираем beat_detector) ==="
paru -S --noconfirm quickshell-git caelestia-cli-git caelestia-shell-git app2unit-git ddcutil brightnessctl cava aubio grim swappy || true

# Создаём директорию для Caelestia конфигов в home пользователя
mkdir -p "${CAELESTIA_TARGET_DIR}"
chown -R "${USERNAME}:${USERNAME}" "$(dirname "${CAELESTIA_TARGET_DIR}")"

# Клонируем repo Caelestia под пользователем (временно как root, потом chown)
cd /home/"${USERNAME}"/.config/quickshell || true
if [ ! -d ".git" ]; then
  git clone https://github.com/caelestia-dots/shell.git caelestia || true
fi
chown -R "${USERNAME}:${USERNAME}" /home/"${USERNAME}"/.config/quickshell/caelestia || true

# Сборка beat_detector (как обычный пользователь — используем runuser)
mkdir -p /usr/lib/caelestia
chmod 755 /usr/lib/caelestia
runuser -u "${USERNAME}" -- bash -lc "cd /home/${USERNAME}/.config/quickshell/caelestia && \
  g++ -std=c++17 -Wall -Wextra -I/usr/include/pipewire-0.3 -I/usr/include/spa-0.2 -I/usr/include/aubio -o beat_detector assets/beat_detector.cpp -lpipewire-0.3 -laubio || true"

# Перемещение бинарника (если собрался)
if [ -f /home/"${USERNAME}"/.config/quickshell/caelestia/beat_detector ]; then
  mv /home/"${USERNAME}"/.config/quickshell/caelestia/beat_detector /usr/lib/caelestia/beat_detector
  chmod 755 /usr/lib/caelestia/beat_detector
fi

# Устанавливаем права и копируем конфиг-пример в ~/.config/caelestia (если нужно)
mkdir -p /home/"${USERNAME}"/.config/caelestia
cp -r /home/"${USERNAME}"/.config/quickshell/caelestia/config/* /home/"${USERNAME}"/.config/caelestia/ 2>/dev/null || true
chown -R "${USERNAME}:${USERNAME}" /home/"${USERNAME}"/.config/caelestia /home/"${USERNAME}"/.config/quickshell/caelestia || true

# Добавим минимальную инструкцию в hyprland config (user может её настроить позже)
mkdir -p /home/"${USERNAME}"/.config/hypr
cat > /home/"${USERNAME}"/.config/hypr/hyprland.conf <<HYPRCONF
# minimal: autostart caelestia (qs is quickshell cli)
exec-once = qs -c caelestia
# you will want to replace or expand this hyprland conf later
HYPRCONF
chown -R "${USERNAME}:${USERNAME}" /home/"${USERNAME}"/.config/hypr

# mkinitcpio (для всех ядер)
mkinitcpio -P || true

# Устанавливаем GRUB (UEFI)
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB || true
grub-mkconfig -o /boot/grub/grub.cfg || true

# Включаем NetworkManager
systemctl enable NetworkManager || true

echo "=== chroot setup finished ==="
CHROOT_SCRIPT

# Подставляем реальные значения в временный скрипт
# используем perl для безопасной замены
perl -0777 -pe "s/DISK_PLACEHOLDER/${DISK}/g; s/HOSTNAME_PLACEHOLDER/${HOSTNAME}/g; s/USERNAME_PLACEHOLDER/${USERNAME}/g; s/TIMEZONE_PLACEHOLDER/${TIMEZONE}/g; s/LOCALE1_PLACEHOLDER/${LOCALE1}/g; s/LOCALE2_PLACEHOLDER/${LOCALE2}/g; s/KEYMAP_PLACEHOLDER/${KEYMAP}/g; s/CPU_THREADS_PLACEHOLDER/${CPU_THREADS}/g; s/PARALLEL_DOWNLOADS_PLACEHOLDER/${PARALLEL_DOWNLOADS}/g; s/MAKEFLAGS_JOBS_PLACEHOLDER/${MAKEFLAGS_JOBS}/g; s/USE_CHAOTIC_PLACEHOLDER/${USE_CHAOTIC}/g; s/INSTALL_XANMOD_PLACEHOLDER/${INSTALL_XANMOD}/g; s/INSTALL_NVIDIA_DKMS_PLACEHOLDER/${INSTALL_NVIDIA_DKMS}/g; s/CAELESTIA_TARGET_DIR_PLACEHOLDER/$(echo ${CAELESTIA_TARGET_DIR} | sed -e 's/\\/\\\\/g')/g; s/ROOT_PASS_PLACEHOLDER/$(echo ${ROOT_PASS} | sed -e 's/\\/\\\\/g' -e \"s/'/'\\\\'\" )/g; s/USER_PASS_PLACEHOLDER/$(echo ${USER_PASS} | sed -e 's/\\/\\\\/g' -e \"s/'/'\\\\'\" )/g;" /mnt/root/chroot_post.sh > /mnt/root/chroot_post_filled.sh

# Делаем исполняемым и выполняем внутри chroot
chmod +x /mnt/root/chroot_post_filled.sh
arch-chroot /mnt /root/chroot_post_filled.sh

# Чистим временные файлы
rm -f /mnt/root/chroot_post.sh /mnt/root/chroot_post_filled.sh

echo "=== Установка завершена. Отмонтируем и перезагружаемся ==="
umount -R /mnt || true
echo "Готово. Введите 'reboot' когда будете готовы."
