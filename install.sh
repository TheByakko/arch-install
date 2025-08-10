#!/usr/bin/env bash
set -u  # убрал pipefail, чтобы не прерывался из-за цепочек

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

# Функция для логирования и игнорирования ошибок
run_cmd() {
  echo ">>> Running: $*"
  "$@" || echo "!!! Warning: команда '$*' завершилась с ошибкой, но установка продолжится."
}

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
run_cmd ping -c3 8.8.8.8

echo "=== 2) Обновление mirrorlist (reflector)..."
run_cmd pacman -Sy --noconfirm reflector
run_cmd reflector --country "Russia,Poland,Germany,Netherlands" --latest 20 --sort rate --protocol https --save /etc/pacman.d/mirrorlist

echo "=== 3) Разметка диска: ${DISK} (GPT, EFI, ext4) ==="
read -p "ВНИМАНИЕ: Это удалит все данные на ${DISK}. Продолжить? [type YES] " CONF
if [[ "$CONF" != "YES" ]]; then
  echo "Отменено."
  exit 3
fi

run_cmd sgdisk --zap-all "${DISK}"
run_cmd parted -s "${DISK}" mklabel gpt
run_cmd parted -s "${DISK}" mkpart ESP fat32 1MiB 513MiB
run_cmd parted -s "${DISK}" set 1 boot on
run_cmd parted -s "${DISK}" mkpart primary ext4 513MiB 100%

# Поддержка NVMe
if [[ "${DISK}" == *"nvme"* ]]; then
  EFI_PART="${DISK}p1"
  ROOT_PART="${DISK}p2"
else
  EFI_PART="${DISK}1"
  ROOT_PART="${DISK}2"
fi

echo "mkfs..."
run_cmd mkfs.fat -F32 "${EFI_PART}"
run_cmd mkfs.ext4 -F "${ROOT_PART}"

echo "монтирование..."
run_cmd mount "${ROOT_PART}" /mnt
mkdir -p /mnt/boot
run_cmd mount "${EFI_PART}" /mnt/boot

echo "=== 4) Установка базовой системы (pacstrap) ==="
run_cmd pacstrap /mnt base base-devel linux linux-headers linux-firmware intel-ucode \
  vim git sudo networkmanager os-prober grub efibootmgr nano wget curl

run_cmd genfstab -U /mnt >> /mnt/etc/fstab

### === 5) Входим в chroot и продолжаем автоматические шаги === ###
cat > /mnt/root/chroot_post.sh <<'CHROOT_SCRIPT'
#!/usr/bin/env bash
set -u

DISK="DISK_PLACEHOLDER"
HOSTNAME="HOSTNAME_PLACEHOLDER"
USERNAME="USERNAME_PLACEHOLDER"
TIMEZONE="TIMEZONE_PLACEHOLDER"
LOCALE1="LOCALE1_PLACEHOLDER"
LOCALE2="LOCALE2_PLACEHOLDER"
KEYMAP="KEYMAP_PLACEHOLDER"
CPU_THREADS="CPU_THREADS_PLACEHOLDER"
PARALLEL_DOWNLOADS="PARALLEL_DOWNLOADS_PLACEHOLDER"
MAKEFLAGS_JOBS="MAKEFLAGS_JOBS_PLACEHOLDER"
USE_CHAOTIC="USE_CHAOTIC_PLACEHOLDER"
INSTALL_XANMOD="INSTALL_XANMOD_PLACEHOLDER"
INSTALL_NVIDIA_DKMS="INSTALL_NVIDIA_DKMS_PLACEHOLDER"
CAELESTIA_TARGET_DIR="CAELESTIA_TARGET_DIR_PLACEHOLDER"
ROOT_PASS="ROOT_PASS_PLACEHOLDER"
USER_PASS="USER_PASS_PLACEHOLDER"

run_cmd() {
  echo ">>> Running: $*"
  "$@" || echo "!!! Warning: команда '$*' завершилась с ошибкой, но установка продолжится."
}

echo "=== chroot: timezone & locale ==="
run_cmd ln -sf /usr/share/zoneinfo/"${TIMEZONE}" /etc/localtime
run_cmd hwclock --systohc

run_cmd sed -i "s/^#\(${LOCALE1} UTF-8\)/\1/" /etc/locale.gen
run_cmd sed -i "s/^#\(${LOCALE2} UTF-8\)/\1/" /etc/locale.gen
run_cmd locale-gen
echo "LANG=${LOCALE1}" > /etc/locale.conf
echo "KEYMAP=${KEYMAP}" > /etc/vconsole.conf

echo "${HOSTNAME}" > /etc/hostname
cat > /etc/hosts <<EOF
127.0.0.1	localhost
::1		localhost
127.0.1.1	${HOSTNAME}.localdomain ${HOSTNAME}
EOF

run_cmd bash -c "echo root:${ROOT_PASS} | chpasswd"
run_cmd useradd -m -G wheel -s /bin/bash "${USERNAME}"
run_cmd bash -c "echo ${USERNAME}:${USER_PASS} | chpasswd"
run_cmd sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

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

run_cmd cp /etc/makepkg.conf /etc/makepkg.conf.bak
if grep -q '^#MAKEFLAGS' /etc/makepkg.conf; then
  sed -i "s|^#MAKEFLAGS=.*|MAKEFLAGS=\"-j${MAKEFLAGS_JOBS}\"|" /etc/makepkg.conf
elif grep -q '^MAKEFLAGS' /etc/makepkg.conf; then
  sed -i "s|^MAKEFLAGS=.*|MAKEFLAGS=\"-j${MAKEFLAGS_JOBS}\"|" /etc/makepkg.conf
else
  echo "MAKEFLAGS=\"-j${MAKEFLAGS_JOBS}\"" >> /etc/makepkg.conf
fi

run_cmd pacman -Syyu --noconfirm

if [ "${USE_CHAOTIC}" = "yes" ]; then
  echo "=== Подключаем Chaotic-AUR ==="
  run_cmd pacman-key --recv-key 3056513887B78AEB --keyserver keyserver.ubuntu.com
  run_cmd pacman-key --lsign-key 3056513887B78AEB
  run_cmd pacman -U --noconfirm https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-keyring.pkg.tar.zst https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-mirrorlist.pkg.tar.zst
  if ! grep -q "^\[chaotic-aur\]" /etc/pacman.conf; then
    cat >> /etc/pacman.conf <<'CHAOTIC'
[chaotic-aur]
Include = /etc/pacman.d/chaotic-mirrorlist
CHAOTIC
  fi
  run_cmd pacman -Syyu --noconfirm
fi

echo "=== Установка paru (AUR helper) ==="
run_cmd pacman -S --needed --noconfirm git base-devel
cd /tmp || exit 1
if ! command -v paru &>/dev/null; then
  run_cmd git clone https://aur.archlinux.org/paru.git
  cd paru || exit 1
  run_cmd makepkg -si --noconfirm
fi
cd / || true

if [ "${INSTALL_XANMOD}" = "yes" ]; then
  echo "=== Установка linux-xanmod из Chaotic/AUR ==="
  run_cmd pacman -S --noconfirm linux-xanmod linux-xanmod-headers
fi

if [ "${INSTALL_NVIDIA_DKMS}" = "yes" ]; then
  echo "=== Установка nvidia-dkms (рекомендуется) и 32-bit libs ==="
  run_cmd pacman -S --noconfirm nvidia-dkms nvidia-utils lib32-nvidia-utils
  run_cmd pacman -S --noconfirm vulkan-icd-loader lib32-vulkan-icd-loader vulkan-tools
fi

echo "=== Установка игрового стека (steam, wine, lutris, mangohud, gamemode) ==="
run_cmd pacman -S --noconfirm steam lutris wine winetricks lib32-alsa-plugins lib32-libpulse gamemode mangohud lib32-mesa
run_cmd paru -S --noconfirm protonup-qt dxvk-bin vkd3d-proton lib32-vkd3d-proton

echo "=== Установка Hyprland + утилит ==="
run_cmd pacman -S --noconfirm hyprland wayland-protocols wlroots xorg-xwayland xdg-desktop-portal-gtk qt6-declarative \
  pipewire pipewire-pulse pipewire-alsa pipewire-jack pamixer pavucontrol \
  kitty cava cmatrix neofetch fastfetch btop grim swappy lm_sensors libqalculate
run_cmd paru -S --noconfirm ttf-material-symbols-variable-git ttf-jetbrains-mono-nerd

echo "=== Установка Quickshell (AUR) и Caelestia (клонируем конфиг и собираем beat_detector) ==="
run_cmd paru -S --noconfirm quickshell-git caelestia-cli-git caelestia-shell-git app2unit-git ddcutil brightnessctl cava aubio grim swappy

run_cmd mkdir -p "${CAELESTIA_TARGET_DIR}"
run_cmd chown -R "${USERNAME}:${USERNAME}" "$(dirname "${CAELESTIA_TARGET_DIR}")"

cd /home/"${USERNAME}"/.config/quickshell || true
if [ ! -d ".git" ]; then
  run_cmd git clone https://github.com/caelestia-dots/shell.git caelestia
fi
run_cmd chown -R "${USERNAME}:${USERNAME}" /home/"${USERNAME}"/.config/quickshell/caelestia

run_cmd mkdir -p /usr/lib/caelestia
run_cmd chmod 755 /usr/lib/caelestia
run_cmd runuser -u "${USERNAME}" -- bash -lc "cd /home/${USERNAME}/.config/quickshell/caelestia && g++ -std=c++17 -Wall -Wextra -I/usr/include/pipewire-0.3 -I/usr/include/spa-0.2 -I/usr/include/aubio -o beat_detector assets/beat_detector.cpp -lpipewire-0.3 -laubio"

if [ -f /home/"${USERNAME}"/.config/quickshell/caelestia/beat_detector ]; then
  run_cmd mv /home/"${USERNAME}"/.config/quickshell/caelestia/beat_detector /usr/lib/caelestia/beat_detector
  run_cmd chmod 755 /usr/lib/caelestia/beat_detector
fi

run_cmd mkdir -p /home/"${USERNAME}"/.config/caelestia
run_cmd cp -r /home/"${USERNAME}"/.config/quickshell/caelestia/config/* /home/"${USERNAME}"/.config/caelestia/ 2>/dev/null
run_cmd chown -R "${USERNAME}:${USERNAME}" /home/"${USERNAME}"/.config/caelestia /home/"${USERNAME}"/.config/quickshell/caelestia

run_cmd mkdir -p /home/"${USERNAME}"/.config/hypr
cat > /home/"${USERNAME}"/.config/hypr/hyprland.conf <<HYPRCONF
# minimal: autostart caelestia (qs is quickshell cli)
exec-once = qs -c caelestia
# you will want to replace or expand this hyprland conf later
HYPRCONF
run_cmd chown -R "${USERNAME}:${USERNAME}" /home/"${USERNAME}"/.config/hypr

run_cmd mkinitcpio -P
run_cmd grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
run_cmd grub-mkconfig -o /boot/grub/grub.cfg

run_cmd systemctl enable NetworkManager

echo "=== chroot setup finished ==="
CHROOT_SCRIPT

# Подставляем реальные значения
perl -0777 -pe "
  s/DISK_PLACEHOLDER/${DISK}/g;
  s/HOSTNAME_PLACEHOLDER/${HOSTNAME}/g;
  s/USERNAME_PLACEHOLDER/${USERNAME}/g;
  s/TIMEZONE_PLACEHOLDER/${TIMEZONE}/g;
  s/LOCALE1_PLACEHOLDER/${LOCALE1}/g;
  s/LOCALE2_PLACEHOLDER/${LOCALE2}/g;
  s/KEYMAP_PLACEHOLDER/${KEYMAP}/g;
  s/CPU_THREADS_PLACEHOLDER/${CPU_THREADS}/g;
  s/PARALLEL_DOWNLOADS_PLACEHOLDER/${PARALLEL_DOWNLOADS}/g;
  s/MAKEFLAGS_JOBS_PLACEHOLDER/${MAKEFLAGS_JOBS}/g;
  s/USE_CHAOTIC_PLACEHOLDER/${USE_CHAOTIC}/g;
  s/INSTALL_XANMOD_PLACEHOLDER/${INSTALL_XANMOD}/g;
  s/INSTALL_NVIDIA_DKMS_PLACEHOLDER/${INSTALL_NVIDIA_DKMS}/g;
  s/CAELESTIA_TARGET_DIR_PLACEHOLDER/$(echo ${CAELESTIA_TARGET_DIR} | sed 's/\\/\\\\/g')/g;
  s/ROOT_PASS_PLACEHOLDER/$(echo ${ROOT_PASS} | sed "s/'/'\\\\''/g")/g;
  s/USER_PASS_PLACEHOLDER/$(echo ${USER_PASS} | sed "s/'/'\\\\''/g")/g;
" /mnt/root/chroot_post.sh > /mnt/root/chroot_post_filled.sh

chmod +x /mnt/root/chroot_post_filled.sh
arch-chroot /mnt /root/chroot_post_filled.sh

# Чистим
rm -f /mnt/root/chroot_post.sh /mnt/root/chroot_post_filled.sh

echo "=== Установка завершена. Отмонтируем и перезагружаемся ==="
run_cmd umount -R /mnt

echo "Готово. Введите 'reboot' когда будете готовы."
