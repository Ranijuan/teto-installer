#!/bin/bash
set -Eeuo pipefail

GREEN='\033[0;32m'
CYAN='\033[0;36m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

show_banner() {
  echo -e "${CYAN}"
  echo "==========================================================="
  echo "   ARCH + HYPRLAND + TETO -- INSTALADOR SEGURIZADO        "
  echo "==========================================================="
  echo -e "${NC}"
}

require_root() {
  if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Error: ejecuta este script como root.${NC}"
    exit 1
  fi
}

check_internet() {
  if ! ping -c 1 archlinux.org &> /dev/null; then
    echo -e "${RED}Error: no hay conexión a internet. Conéctate primero con iwctl o ethernet.${NC}"
    exit 1
  fi
}

choose_disk() {
  echo -e "\n${YELLOW}Discos detectados:${NC}"
  lsblk -d -o NAME,SIZE,TYPE | grep -E 'disk|nvme|sd|mmcblk' || true
  echo
  read -r -p "Escribe el disco objetivo (ejemplo: /dev/nvme0n1): " DISK

  if ! echo "$DISK" | grep -Eq '^/dev/(nvme|sd|vd|mmcblk)'; then
    echo -e "${RED}Disco no válido: $DISK${NC}"
    exit 1
  fi

  if [ ! -b "$DISK" ]; then
    echo -e "${RED}El disco no existe: $DISK${NC}"
    exit 1
  fi

  echo -e "${GREEN}Destino seleccionado: $DISK${NC}"
}

confirm_wipe() {
  echo -e "\n${RED}ATENCIÓN: Este paso BORRARÁ el disco $DISK${NC}"
  echo -e "${RED}Se crearán particiones, se formateará y se instalará Arch sobre él.${NC}"
  echo -e "${RED}Se recomienda hacerlo solo si estás seguro de lo que estás haciendo.${NC}"
  read -r -p "Escribe EXACTAMENTE 'TETO-ERASE' para continuar: " CONFIRM
  if [ "$CONFIRM" != "TETO-ERASE" ]; then
    echo "Abortado por seguridad."
    exit 1
  fi
}

create_partitions() {
  echo -e "\n${YELLOW}>>> Creando particiones GPT...${NC}"
  sgdisk --zap-all "$DISK"
  sgdisk -n 1:0:+1GiB -t 1:ef00 -c 1:EFI "$DISK"
  sgdisk -n 2:0:0 -t 2:8300 -c 2:ROOT "$DISK"

  EFI_PART="${DISK}1"
  ROOT_PART="${DISK}2"

  if ! [ -b "$EFI_PART" ] || ! [ -b "$ROOT_PART" ]; then
    echo -e "${RED}No se pudieron crear las particiones correctamente.${NC}"
    exit 1
  fi

  echo -e "Partición EFI: ${GREEN}$EFI_PART${NC}"
  echo -e "Partición ROOT: ${GREEN}$ROOT_PART${NC}"

  mkfs.fat -F32 "$EFI_PART"
  mkfs.btrfs -f "$ROOT_PART"
}

setup_btrfs_mounts() {
  echo -e "\n${YELLOW}>>> Montando sistema raíz en /mnt...${NC}"
  mount "$ROOT_PART" /mnt
  btrfs subvolume create /mnt/@
  btrfs subvolume create /mnt/@home
  btrfs subvolume create /mnt/@log
  btrfs subvolume create /mnt/@pkg
  btrfs subvolume create /mnt/@snapshots
  umount /mnt

  mount -o compress=zstd,subvol=@ "$ROOT_PART" /mnt
  mkdir -p /mnt/{boot,home,var/log,var/cache/pacman/pkg,.snapshots}
  mount -o compress=zstd,subvol=@home "$ROOT_PART" /mnt/home
  mount -o compress=zstd,subvol=@log "$ROOT_PART" /mnt/var/log
  mount -o compress=zstd,subvol=@pkg "$ROOT_PART" /mnt/var/cache/pacman/pkg
  mount -o compress=zstd,subvol=@snapshots "$ROOT_PART" /mnt/.snapshots
  mount "$EFI_PART" /mnt/boot
}

write_archinstall_config() {
  echo -e "\n${YELLOW}>>> Generando configuración de Archinstall...${NC}"
  cat > /tmp/archinstall.json <<EOF
{
  "bootloader": "grub",
  "audio": "pipewire",
  "kernels": ["linux"],
  "network_manager": "NetworkManager",
  "multilib": true,
  "timezone": "America/Bogota",
  "keyboard_layout": "la-latin1",
  "hostname": "teto-arch",
  "users": [
    {
      "username": "ranijuan",
      "password": "teto123",
      "sudo": true,
      "groups": ["wheel"],
      "shell": "/bin/bash"
    }
  ],
  "custom_commands": [
    "pacman -S --noconfirm os-prober",
    "echo 'GRUB_DISABLE_OS_PROBER=false' >> /etc/default/grub"
  ]
}
EOF
}

install_base_system() {
  echo -e "\n${YELLOW}>>> Instalando Arch Linux (esto puede tardar varios minutos)...${NC}"
  archinstall --config /tmp/archinstall.json --silent
}

prepare_post_install() {
  echo -e "\n${YELLOW}>>> Descargando wallpapers y preparando configuración post-instalar...${NC}"
  mkdir -p /mnt/root/wallpapers
  curl -fsSL "https://files.catbox.moe/8b3p8h.jpg" -o /mnt/root/wallpapers/teto_01.jpg || true
  curl -fsSL "https://files.catbox.moe/7n4z9x.jpg" -o /mnt/root/wallpapers/teto_02.jpg || true

  cat > /mnt/root/post-install.sh <<'EOF'
#!/bin/bash
set -Eeuo pipefail

pacman -S --noconfirm base-devel git
cd /tmp
rm -rf yay
if [ ! -d /tmp/yay ]; then
  git clone https://aur.archlinux.org/yay.git
fi
chown -R ranijuan:ranijuan /tmp/yay
cd /tmp/yay
sudo -u ranijuan makepkg -si --noconfirm

sudo -u ranijuan yay -S --noconfirm caelestia-cli
sudo -u ranijuan caelestia install --yes || true

if ! [ -f /etc/greetd/config.toml ]; then
  mkdir -p /etc/greetd
fi
cat > /etc/greetd/config.toml <<'GREET'
[daemon]
command = "tuigreet --cmd Hyprland"

[terminal]
vt = 1

[default_session]
command = "agreety --cmd Hyprland"
user = "greeter"
GREET
systemctl enable greetd

cat > /etc/sudoers.d/10-ranijuan-nopasswd <<'SUDO'
ranijuan ALL=(ALL) NOPASSWD: ALL
SUDO
chmod 440 /etc/sudoers.d/10-ranijuan-nopasswd
mkdir -p /etc/polkit-1/rules.d
cat > /etc/polkit-1/rules.d/49-nopasswd-wheel.rules <<'RULE'
polkit.addRule(function(action, subject) {
  if (subject.isInGroup("wheel")) {
    return polkit.Result.YES;
  }
});
RULE

pacman -S --noconfirm power-profiles-daemon zram-generator bluez bluez-utils blueman ntfs-3g exfatprogs libreoffice-fresh okular mpv firefox discord steam lutris heroic-games-launcher-bin vulkan-radeon lib32-vulkan-radeon gamemode lib32-gamemode mangohud lib32-mangohud ufw snapper snap-pac grub-btrfs piper input-remapper
systemctl enable bluetooth
systemctl enable power-profiles-daemon
ufw default deny incoming
ufw default allow outgoing
ufw enable
systemctl enable grub-btrfsd
snapper -c root create-config /
systemctl enable snapper-timeline.timer
systemctl enable snapper-cleanup.timer
systemctl enable ratbagd

mkdir -p /home/ranijuan/Pictures/Wallpapers
if [ -d /root/wallpapers ]; then
  cp -f /root/wallpapers/*.jpg /home/ranijuan/Pictures/Wallpapers/ 2>/dev/null || true
fi
chown -R ranijuan:ranijuan /home/ranijuan/Pictures

mkdir -p /home/ranijuan/.config/hypr
cat > /home/ranijuan/.config/hypr/cycle-wallpaper.sh <<'WALL'
#!/bin/bash
set -e
WALL_DIR="$HOME/Pictures/Wallpapers"
if [ ! -d "$WALL_DIR" ]; then
  exit 0
fi
CURRENT=$(caelestia wallpaper get 2>/dev/null | xargs basename || true)
WALLS=($(ls "$WALL_DIR" 2>/dev/null))
if [ ${#WALLS[@]} -eq 0 ]; then
  exit 0
fi
for i in "${!WALLS[@]}"; do
  if [[ "${WALLS[$i]}" == "$CURRENT" ]]; then
    NEXT_INDEX=$(( (i + 1) % ${#WALLS[@]} ))
    NEXT_WALL="${WALLS[$NEXT_INDEX]}"
    caelestia wallpaper -f "$WALL_DIR/$NEXT_WALL"
    caelestia scheme set -n dynamic
    notify-send "Teto Wallpaper" "$NEXT_WALL"
    exit 0
  fi
done
caelestia wallpaper -f "$WALL_DIR/${WALLS[0]}"
caelestia scheme set -n dynamic
WALL
chmod +x /home/ranijuan/.config/hypr/cycle-wallpaper.sh
chown ranijuan:ranijuan /home/ranijuan/.config/hypr/cycle-wallpaper.sh

cat > /home/ranijuan/.config/hypr/hypr-user.lua <<'LUA'
local hl = require("hyprland")
hl.config({
  general = {
    gaps_in = 4,
    gaps_out = 8,
    border_size = 2,
    col.active_border = "rgba(ff0044ee) rgba(880022ee) 45deg",
  },
  input = {
    kb_layout = "la-latin1",
    sensitivity = 0.2,
  },
  binds = {
    { mods = "SUPER SHIFT", key = "W", dispatcher = "exec", cmd = "~/.config/hypr/cycle-wallpaper.sh" },
    { mods = "SUPER", key = "T", dispatcher = "exec", cmd = "foot" },
    { mods = "SUPER", key = "W", dispatcher = "exec", cmd = "firefox" },
    { mods = "SUPER", key = "E", dispatcher = "exec", cmd = "thunar" },
  }
})
LUA
chown ranijuan:ranijuan /home/ranijuan/.config/hypr/hypr-user.lua

FIRST_WALL=$(ls /home/ranijuan/Pictures/Wallpapers/*.jpg 2>/dev/null | head -n 1 || true)
if [ -n "$FIRST_WALL" ]; then
  sudo -u ranijuan caelestia wallpaper -f "$FIRST_WALL"
  sudo -u ranijuan caelestia scheme set -n dynamic
fi

echo "Sistema Teto listo."
EOF

  chmod +x /mnt/root/post-install.sh
}

run_post_install() {
  echo -e "\n${YELLOW}>>> Ejecutando configuración final dentro del sistema recién instalado...${NC}"
  arch-chroot /mnt bash /root/post-install.sh
}

finalize() {
  echo -e "\n${GREEN}==========================================================${NC}"
  echo -e "${GREEN}   INSTALACIÓN COMPLETADA                              ${NC}"
  echo -e "${GREEN}==========================================================${NC}"
  echo -e "${CYAN}Reinicia el equipo y entra en tu nueva instalación de Arch + Hyprland.${NC}"
  umount -R /mnt || true
  read -r -p "¿Quieres reiniciar ahora? [s/N]: " REBOOT_NOW
  if [[ "$REBOOT_NOW" =~ ^[sS]$ ]]; then
    reboot
  fi
}

main() {
  show_banner
  require_root
  check_internet
  choose_disk
  confirm_wipe
  create_partitions
  setup_btrfs_mounts
  write_archinstall_config
  install_base_system
  prepare_post_install
  run_post_install
  finalize
}

main "$@"
