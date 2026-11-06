#!/bin/bash
set -e

GREEN='\033[0;32m'
CYAN='\033[0;36m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${CYAN}"
echo "==========================================================="
echo "   INSTALADOR ZERO-TOUCH: ARCH LINUX + HYPRLAND + TETO     "
echo "==========================================================="
echo -e "${NC}"

if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Error: Ejecuta este script como root.${NC}"
  exit 1
fi

if ! ping -c 1 archlinux.org &> /dev/null; then
  echo -e "${RED}Error: No hay conexión a internet. Conéctate primero (iwctl).${NC}"
  exit 1
fi

echo -e "${YELLOW}>>> Analizando el hardware...${NC}"

DISK=$(lsblk -dpno NAME | grep -E "/dev/(nvme|sd|vd)" | head -n 1)
if [ -z "$DISK" ]; then
    echo -e "${RED}No se pudo detectar el disco principal.${NC}"; exit 1
fi

EFI_PART=$(lsblk -lpo NAME,FSTYPE | grep vfat | awk '{print $1}' | head -n 1)
if [ -z "$EFI_PART" ]; then
    echo -e "${RED}No se pudo detectar la partición EFI de Windows.${NC}"; exit 1
fi

echo -e "Disco detectado: ${GREEN}$DISK${NC}"
echo -e "Partición EFI detectada: ${GREEN}$EFI_PART${NC}"

echo -e "\n${RED}¡ATENCIÓN! Se instalará Arch Linux usando el espacio libre en $DISK.${NC}"
read -p "Escribe 'TETO' para comenzar la instalación automática: " CONFIRM
if [ "$CONFIRM" != "TETO" ]; then echo "Abortando."; exit 1; fi

echo -e "\n${YELLOW}>>> Creando partición para Arch en el espacio libre...${NC}"
sgdisk -n 0:0:0 -t 0:8300 "$DISK" || true
PART_ARCH=$(lsblk -lpo NAME | grep "$DISK" | tail -n 1)
echo -e "Nueva partición creada: ${GREEN}$PART_ARCH${NC}"

echo -e "\n${YELLOW}>>> Formateando y creando subvolúmenes...${NC}"
mkfs.btrfs -f "$PART_ARCH"
mount "$PART_ARCH" /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@log
btrfs subvolume create /mnt/@pkg
btrfs subvolume create /mnt/@snapshots
umount /mnt

mount -o compress=zstd,subvol=@ "$PART_ARCH" /mnt
mkdir -p /mnt/{home,var/log,var/cache/pacman/pkg,.snapshots,boot}
mount -o compress=zstd,subvol=@home "$PART_ARCH" /mnt/home
mount -o compress=zstd,subvol=@log "$PART_ARCH" /mnt/var/log
mount -o compress=zstd,subvol=@pkg "$PART_ARCH" /mnt/var/cache/pacman/pkg
mount -o compress=zstd,subvol=@snapshots "$PART_ARCH" /mnt/.snapshots
mount "$EFI_PART" /mnt/boot

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

echo -e "\n${YELLOW}>>> Instalando Arch Linux (Esto tomará unos minutos)...${NC}"
archinstall --config /tmp/archinstall.json --silent

echo -e "\n${YELLOW}>>> Preparando configuración de Caelestia y Teto...${NC}"

mkdir -p /mnt/root/wallpapers
curl -sL "https://files.catbox.moe/8b3p8h.jpg" -o /mnt/root/wallpapers/teto_01.jpg
curl -sL "https://files.catbox.moe/7n4z9x.jpg" -o /mnt/root/wallpapers/teto_02.jpg

cat > /mnt/root/post-install.sh <<'EOF'
#!/bin/bash
set -e
pacman -S --noconfirm base-devel git
cd /tmp
git clone https://aur.archlinux.org/yay.git
chown -R ranijuan:ranijuan yay
cd yay
sudo -u ranijuan makepkg -si --noconfirm
cd ~

sudo -u ranijuan yay -S --noconfirm caelestia-cli
sudo -u ranijuan caelestia install --yes

echo '[daemon]' > /etc/greetd/config.toml
echo 'service = "tuigreet --cmd Hyprland"' >> /etc/greetd/config.toml
systemctl enable greetd

echo "ranijuan ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/10-ranijuan-nopasswd
chmod 440 /etc/sudoers.d/10-ranijuan-nopasswd
mkdir -p /etc/polkit-1/rules.d
echo 'polkit.addRule(function(action, subject) { if (subject.isInGroup("wheel")) { return polkit.Result.YES; } });' > /etc/polkit-1/rules.d/49-nopasswd-wheel.rules

pacman -S --noconfirm power-profiles-daemon zram-generator
systemctl enable power-profiles-daemon

pacman -S --noconfirm bluez bluez-utils blueman ntfs-3g exfatprogs libreoffice-fresh okular mpv firefox discord spotify-launcher steam lutris heroic-games-launcher-bin vulkan-radeon lib32-vulkan-radeon gamemode lib32-gamemode mangohud lib32-mangohud ufw snapper snap-pac grub-btrfs
systemctl enable bluetooth
ufw default deny incoming
ufw default allow outgoing
ufw enable
systemctl enable grub-btrfsd
snapper -c root create-config /
systemctl enable snapper-timeline.timer
systemctl enable snapper-cleanup.timer

pacman -S --noconfirm piper input-remapper
systemctl enable ratbagd

mkdir -p /home/ranijuan/Pictures/Wallpapers
cp /root/wallpapers/*.jpg /home/ranijuan/Pictures/Wallpapers/ 2>/dev/null || true
chown -R ranijuan:ranijuan /home/ranijuan/Pictures

mkdir -p /home/ranijuan/.config/hypr
cat > /home/ranijuan/.config/hypr/cycle-wallpaper.sh <<'WALL'
#!/bin/bash
WALL_DIR="$HOME/Pictures/Wallpapers"
CURRENT=$(caelestia wallpaper get | xargs basename)
WALLS=($(ls "$WALL_DIR"))
if [ ${#WALLS[@]} -eq 0 ]; then exit 0; fi
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

FIRST_WALL=$(ls /home/ranijuan/Pictures/Wallpapers/*.jpg | head -n 1)
if [ -n "$FIRST_WALL" ]; then
    sudo -u ranijuan caelestia wallpaper -f "$FIRST_WALL"
    sudo -u ranijuan caelestia scheme set -n dynamic
fi

echo "¡Sistema Teto configurado con éxito!"
EOF

chmod +x /mnt/root/post-install.sh

echo -e "\n${YELLOW}>>> Configurando el sistema de Teto (Caelestia, atajos, wallpapers)...${NC}"
arch-chroot /mnt bash /root/post-install.sh

echo -e "\n${GREEN}==========================================================${NC}"
echo -e "${GREEN}   ¡INSTALACIÓN COMPLETADA CON ÉXITO!                     ${NC}"
echo -e "${GREEN}==========================================================${NC}"
umount -R /mnt
echo -e "${CYAN}Retira el USB y presiona ENTER para reiniciar en tu nuevo Arch-Teto.${NC}"
read -p ""
reboot
