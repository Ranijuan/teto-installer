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
  echo "   ARCH + HYPRLAND + TETO -- INSTALADOR SOLO PARTICIÓN     "
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

choose_root_partition() {
  echo -e "\n${YELLOW}Particiones actuales:${NC}"
  lsblk -o NAME,SIZE,FSTYPE,TYPE,MOUNTPOINTS
  echo
  read -r -p "Escribe la partición raíz donde instalar Arch (ej: /dev/nvme0n1p4): " ROOT_PART

  if ! echo "$ROOT_PART" | grep -Eq '^/dev/(nvme|sd|vd|mmcblk)[a-zA-Z0-9]*p?[0-9]+$'; then
    echo -e "${RED}Ruta de partición no válida: $ROOT_PART${NC}"
    exit 1
  fi

  if [ ! -b "$ROOT_PART" ]; then
    echo -e "${RED}La partición no existe: $ROOT_PART${NC}"
    exit 1
  fi

  if lsblk -no MOUNTPOINTS "$ROOT_PART" | grep -q '[^[:space:]]'; then
    echo -e "${RED}La partición ya está montada. Desmóntala antes.${NC}"
    exit 1
  fi

  echo -e "${GREEN}Se usará la partición raíz: $ROOT_PART${NC}"
}

auto_detect_efi() {
  local disk
  disk=$(lsblk -no PKNAME "$ROOT_PART" 2>/dev/null || true)
  if [ -n "$disk" ]; then
    local efi_candidate
    efi_candidate=$(lsblk -dn -o NAME /dev/"$disk" | awk '{print "/dev/" $1}' | while read -r dev; do
      if [ "$(lsblk -no FSTYPE "$dev" 2>/dev/null || true)" = "vfat" ]; then
        echo "$dev"
      fi
    done | head -n 1 || true)
    if [ -n "$efi_candidate" ]; then
      echo "$efi_candidate"
      return 0
    fi
  fi

  local fallback
  fallback=$(lsblk -lpo NAME,FSTYPE | awk '$2=="vfat" {print $1}' | head -n 1 || true)
  if [ -n "$fallback" ]; then
    echo "$fallback"
    return 0
  fi

  return 1
}

choose_efi_partition() {
  EFI_PART=""
  if EFI_PART=$(auto_detect_efi); then
    echo -e "${GREEN}EFI detectada automáticamente: $EFI_PART${NC}"
  else
    echo -e "${YELLOW}No se detectó una partición EFI. Debes crear o indicar una de 512MB o más con formato vfat.${NC}"
    read -r -p "Escribe la partición EFI (ej: /dev/nvme0n1p1). Si no existe, pulsa Enter para abortar: " EFI_PART
    if [ -z "$EFI_PART" ]; then
      echo -e "${RED}Se requiere una partición EFI para instalar con UEFI.${NC}"
      exit 1
    fi
  fi

  if [ ! -b "$EFI_PART" ]; then
    echo -e "${RED}La partición EFI no existe: $EFI_PART${NC}"
    exit 1
  fi

  if [ "$(lsblk -no FSTYPE "$EFI_PART" 2>/dev/null || true)" != "vfat" ]; then
    echo -e "${RED}La partición EFI debe estar formateada como vfat: $EFI_PART${NC}"
    exit 1
  fi
}

confirm_wipe() {
  echo -e "\n${RED}ATENCIÓN: solo se formateará la partición raíz $ROOT_PART${NC}"
  echo -e "${RED}La partición EFI $EFI_PART se usará y no se borrará.${NC}"
  echo -e "${RED}Esto no toca el disco completo.${NC}"
  read -r -p "Escribe EXACTAMENTE 'TETO-PART' para continuar: " CONFIRM
  if [ "$CONFIRM" != "TETO-PART" ]; then
    echo "Abortado por seguridad."
    exit 1
  fi
}

prepare_filesystem() {
  echo -e "\n${YELLOW}>>> Formateando la partición raíz $ROOT_PART ...${NC}"
  wipefs -a "$ROOT_PART"
  mkfs.btrfs -f "$ROOT_PART"

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
  echo -e "\n${YELLOW}>>> Instalando Arch Linux sobre $ROOT_PART ...${NC}"
  archinstall --config /tmp/archinstall.json --silent
}

prepare_post_install() {
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

mkdir -p /etc/greetd
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
    exit 0
  fi
done
caelestia wallpaper -f "$WALL_DIR/${WALLS[0]}"
caelestia scheme set -n dynamic
WALL
chmod +x /home/ranijuan/.config/hypr/cycle-wallpaper.sh
chown -R ranijuan:ranijuan /home/ranijuan/.config/hypr

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
  echo -e "${GREEN}   INSTALACIÓN COMPLETADA EN LA PARTICIÓN $ROOT_PART      ${NC}"
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
  choose_root_partition
  choose_efi_partition
  confirm_wipe
  prepare_filesystem
  write_archinstall_config
  install_base_system
  prepare_post_install
  run_post_install
  finalize
}

main "$@"
