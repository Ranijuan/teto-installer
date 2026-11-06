#!/usr/bin/env bash
set -Eeuo pipefail

# Instala Arch solo en una partición raíz seleccionada. No crea ni modifica
# la tabla de particiones. La partición EFI elegida se monta sin formatearla.

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

fail() { echo -e "${RED}Error: $*${NC}" >&2; exit 1; }
info() { echo -e "${CYAN}$*${NC}"; }
warn() { echo -e "${YELLOW}$*${NC}"; }

[[ $EUID -eq 0 ]] || fail 'Arranca desde la ISO oficial de Arch y ejecuta como root.'
[[ -d /sys/firmware/efi ]] || fail 'El equipo no arrancó en modo UEFI. Reinicia la ISO en modo UEFI.'
for cmd in lsblk findmnt pacstrap genfstab arch-chroot mkfs.btrfs btrfs grub-install grub-mkconfig; do
  command -v "$cmd" >/dev/null || fail "Falta '$cmd'. Usa una ISO oficial reciente de Arch Linux."
done

clear || true
info '=== Instalador Arch + Hyprland (destino: una partición) ==='
warn 'No se reparticiona ningún disco. La partición raíz que elijas sí será FORMATEADA.'
echo
lsblk -d -o NAME,MODEL,SIZE,TYPE

echo
read -r -p 'Disco donde está la partición destino (ej. /dev/nvme0n1): ' DISK
[[ -b "$DISK" ]] || fail "No existe el dispositivo: $DISK"
[[ "$(lsblk -dnro TYPE "$DISK")" == disk ]] || fail 'Debes introducir el disco completo (TYPE=disk), no una partición.'
DISK=$(readlink -f "$DISK")
DISK_SIZE=$(lsblk -dnro SIZE "$DISK")

echo
info "Disco elegido: $DISK — capacidad: $DISK_SIZE"
echo 'Particiones detectadas en ese disco:'
lsblk -rpo NAME,SIZE,TYPE,FSTYPE,PARTLABEL,MOUNTPOINTS "$DISK"

mapfile -t PARTITIONS < <(lsblk -nrpo NAME,TYPE "$DISK" | awk '$2 == "part" {print $1}')
((${#PARTITIONS[@]} > 0)) || fail 'No se encontraron particiones en ese disco.'

echo
for i in "${!PARTITIONS[@]}"; do
  p=${PARTITIONS[$i]}
  printf '  [%d] %s | tamaño: %s | sistema: %s | montada en: %s\n' \
    "$((i+1))" "$p" "$(lsblk -dnro SIZE "$p")" \
    "$(lsblk -dnro FSTYPE "$p" | xargs)" \
    "$(findmnt -rn -S "$p" -o TARGET | paste -sd, -)"
done

read -r -p 'Número de la partición ROOT que se formateará: ' ROOT_INDEX
[[ "$ROOT_INDEX" =~ ^[0-9]+$ ]] || fail 'Debes introducir un número de la lista.'
((ROOT_INDEX >= 1 && ROOT_INDEX <= ${#PARTITIONS[@]})) || fail 'Número de partición fuera de rango.'
ROOT_PART=${PARTITIONS[$((ROOT_INDEX-1))]}

# Solo ofrecer como EFI particiones vfat del mismo disco y distintas de ROOT.
EFI_CANDIDATES=()
for p in "${PARTITIONS[@]}"; do
  [[ "$p" != "$ROOT_PART" ]] || continue
  [[ "$(lsblk -dnro FSTYPE "$p" | xargs)" == vfat ]] || continue
  EFI_CANDIDATES+=("$p")
done
((${#EFI_CANDIDATES[@]} > 0)) || fail 'No se encontró una partición EFI vfat en el disco. No se formateará ni creará una automáticamente.'

echo
info 'Particiones EFI candidatas (se usarán sin formatear):'
for i in "${!EFI_CANDIDATES[@]}"; do
  p=${EFI_CANDIDATES[$i]}
  printf '  [%d] %s | tamaño: %s | montada en: %s\n' \
    "$((i+1))" "$p" "$(lsblk -dnro SIZE "$p")" \
    "$(findmnt -rn -S "$p" -o TARGET | paste -sd, -)"
done
read -r -p 'Número de la partición EFI que se usará (NO se formateará): ' EFI_INDEX
[[ "$EFI_INDEX" =~ ^[0-9]+$ ]] || fail 'Debes introducir un número de la lista EFI.'
((EFI_INDEX >= 1 && EFI_INDEX <= ${#EFI_CANDIDATES[@]})) || fail 'Número EFI fuera de rango.'
EFI_PART=${EFI_CANDIDATES[$((EFI_INDEX-1))]}

[[ "$ROOT_PART" != "$EFI_PART" ]] || fail 'ROOT y EFI no pueden ser la misma partición.'
findmnt -rn -S "$ROOT_PART" >/dev/null && fail "La partición raíz está montada: $ROOT_PART"
findmnt -rn -S "$EFI_PART" >/dev/null && fail "La partición EFI está montada: $EFI_PART. Desmóntala antes de continuar."

ROOT_SIZE_BYTES=$(lsblk -bdnro SIZE "$ROOT_PART")
((ROOT_SIZE_BYTES >= 20*1024*1024*1024)) || fail 'La partición ROOT debe tener al menos 20 GiB; 40 GiB es suficiente para una instalación básica.'

# Confirmación explícita: si no es s/S, no se escribe nada.
echo
warn 'REVISA cuidadosamente estos datos:'
echo "  Disco (no se reparticionará): $DISK — $DISK_SIZE"
echo "  ROOT (SE FORMATEARÁ Y SE BORRARÁ SU CONTENIDO): $ROOT_PART — $(lsblk -dnro SIZE "$ROOT_PART")"
echo "  EFI (se montará en /boot; NO se formateará): $EFI_PART — $(lsblk -dnro SIZE "$EFI_PART")"
echo '  Todas las demás particiones se dejan sin formato.'
echo
read -r -p "¿Continuar con la instalación en $ROOT_PART? Escribe s para sí o n para cancelar [s/n]: " ANSWER
[[ "$ANSWER" == s || "$ANSWER" == S ]] || { echo 'Cancelado. No se realizaron cambios.'; exit 0; }

read -r -p 'Nombre de usuario nuevo (letras minúsculas/números/guion bajo): ' USERNAME
[[ "$USERNAME" =~ ^[a-z_][a-z0-9_-]*$ ]] || fail 'Nombre de usuario no válido.'
read -r -s -p 'Contraseña para el usuario: ' USER_PASS; echo
read -r -s -p 'Repite la contraseña: ' USER_PASS_CONFIRM; echo
[[ -n "$USER_PASS" && "$USER_PASS" == "$USER_PASS_CONFIRM" ]] || fail 'Contraseñas vacías o no coinciden.'

cleanup() { if mountpoint -q /mnt; then umount -R /mnt || true; fi; }
trap cleanup EXIT

info "Formateando únicamente $ROOT_PART como Btrfs..."
mkfs.btrfs -f "$ROOT_PART"
mount "$ROOT_PART" /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
umount /mnt
mount -o noatime,compress=zstd,subvol=@ "$ROOT_PART" /mnt
mkdir -p /mnt/{boot,home}
mount -o noatime,compress=zstd,subvol=@home "$ROOT_PART" /mnt/home
mount "$EFI_PART" /mnt/boot

info 'Instalando Arch Linux y Hyprland...'
pacstrap -K /mnt base linux linux-firmware btrfs-progs grub efibootmgr sudo \
  networkmanager hyprland xdg-desktop-portal-hyprland waybar foot firefox \
  pipewire wireplumber pipewire-pulse mesa git nano

genfstab -U /mnt >> /mnt/etc/fstab

arch-chroot /mnt ln -sf /usr/share/zoneinfo/America/Bogota /etc/localtime
arch-chroot /mnt hwclock --systohc
sed -i 's/^#es_CO.UTF-8 UTF-8/es_CO.UTF-8 UTF-8/' /mnt/etc/locale.gen
sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /mnt/etc/locale.gen
arch-chroot /mnt locale-gen
printf 'LANG=es_CO.UTF-8\n' > /mnt/etc/locale.conf
printf 'KEYMAP=la-latin1\n' > /mnt/etc/vconsole.conf
printf 'teto-arch\n' > /mnt/etc/hostname
cat > /mnt/etc/hosts <<'HOSTS'
127.0.0.1 localhost
::1       localhost
127.0.1.1 teto-arch.localdomain teto-arch
HOSTS

arch-chroot /mnt useradd -m -G wheel -s /bin/bash "$USERNAME"
printf '%s:%s\n' "$USERNAME" "$USER_PASS" | arch-chroot /mnt chpasswd
unset USER_PASS USER_PASS_CONFIRM
printf '%%wheel ALL=(ALL:ALL) ALL\n' > /mnt/etc/sudoers.d/10-wheel
chmod 440 /mnt/etc/sudoers.d/10-wheel
arch-chroot /mnt systemctl enable NetworkManager

info 'Instalando GRUB en la partición EFI seleccionada (sin formatearla)...'
arch-chroot /mnt grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=Arch --recheck
arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg

trap - EXIT
umount -R /mnt
info 'Instalación base completada.'
echo 'Reinicia y entra con el usuario creado. Para iniciar la sesión gráfica, ejecuta: Hyprland'
echo 'La partición EFI fue conservada; ROOT fue formateada. No se configuró Caelestia/AUR automáticamente.'
read -r -p '¿Reiniciar ahora? [s/n]: ' REBOOT_ANSWER
if [[ "$REBOOT_ANSWER" == s || "$REBOOT_ANSWER" == S ]]; then reboot; fi
