#!/usr/bin/env bash
# =============================================================================
#  Arch Linux + Hyprland + Caelestia · dual boot con Windows · estilo "Teto"
#
#  Ejecutar como root desde la ISO oficial de Arch, arrancada en modo UEFI.
#  Requiere internet. NO reparticiona nada: solo formatea la partición ROOT
#  que elijas y reutiliza (sin formatear) la EFI donde ya vive Windows.
#
#  Ajustes opcionales (variables de entorno), por ejemplo:
#     TIMEZONE=America/Mexico_City HYPR_KB_LAYOUT=latam bash install.sh
# =============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ASSETS_DIR="$SCRIPT_DIR/assets"
WALL_SRC="$SCRIPT_DIR/wallpapers"
LOG=/tmp/teto-install.log
MNT=/mnt

# ---------------------------- Ajustes ----------------------------------------
: "${TIMEZONE:=America/Bogota}"
: "${LOCALE_MAIN:=es_CO.UTF-8}"
: "${CONSOLE_KEYMAP:=la-latin1}"      # teclado de la consola (TTY)
: "${HYPR_KB_LAYOUT:=latam}"          # teclado dentro de Hyprland
: "${HOSTNAME_NEW:=teto-arch}"
: "${USER_SHELL:=/usr/bin/fish}"      # las dots de Caelestia están pensadas para fish
: "${DEFAULT_WALLPAPER:=IMG_3004.jpg}" # fondo inicial (de tu carpeta wallpapers/)
: "${WINDOWS_TITLE:=Windows}"
: "${GRUB_TIMEOUT_SECS:=5}"
: "${MIN_ROOT_GIB:=25}"

ESP_GUID='c12a7328-f81f-11d2-ba4b-00a0c93ec93b'
MSR_GUID='e3c9e316-0b5c-4db8-817d-f92df00215ae'
WINRE_GUID='de94bba4-06d1-4d40-a16a-bfd50179d6ac'

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; CYAN=$'\033[0;36m'; NC=$'\033[0m'
fail() { echo "${RED}Error: $*${NC}" >&2; exit 1; }
info() { echo "${CYAN}$*${NC}"; }
warn() { echo "${YELLOW}$*${NC}"; }
ok()   { echo "${GREEN}$*${NC}"; }

trap 'echo "${RED}Falló la línea $LINENO: $BASH_COMMAND${NC}" >&2' ERR

MOUNTED=0
cleanup() {
  # Pase lo que pase: quitar el sudo sin contraseña temporal y desmontar.
  rm -f "$MNT/etc/sudoers.d/90-teto-temp-nopasswd" 2>/dev/null || true
  rm -rf "$MNT/opt/teto-install" 2>/dev/null || true
  if [[ $MOUNTED -eq 1 ]] && mountpoint -q "$MNT"; then
    umount -R "$MNT" 2>/dev/null || true
  fi
}
trap cleanup EXIT

# --------------------------- Utilidades de disco -----------------------------
part_fs()    { lsblk -dnro FSTYPE "$1" | head -n1; }
part_label() { lsblk -dnro LABEL "$1" | head -n1; }
part_size()  { lsblk -dnro SIZE "$1" | head -n1; }
part_ptype() { lsblk -dnro PARTTYPE "$1" | head -n1 | tr '[:upper:]' '[:lower:]'; }

part_tag() {
  local p=$1 t fs tag=''
  t=$(part_ptype "$p"); fs=$(part_fs "$p")
  case "$t" in
    "$ESP_GUID")   tag='[EFI — se comparte con Windows, NO formatear]' ;;
    "$MSR_GUID")   tag='[Reservada de Windows — NO tocar]' ;;
    "$WINRE_GUID") tag='[Recuperación de Windows — NO tocar]' ;;
  esac
  case "$fs" in
    ntfs|BitLocker|crypto_BitLocker) tag="$tag [¿Windows? NTFS/BitLocker — NO formatear]" ;;
  esac
  printf '%s' "$tag"
}

is_protected() {   # ¿parece una partición de Windows / EFI?
  local p=$1 t fs
  t=$(part_ptype "$p"); fs=$(part_fs "$p")
  case "$t" in "$ESP_GUID"|"$MSR_GUID"|"$WINRE_GUID") return 0 ;; esac
  case "$fs" in ntfs|BitLocker|crypto_BitLocker) return 0 ;; esac
  return 1
}

# ------------------------------ Comprobaciones -------------------------------
preflight() {
  [[ $EUID -eq 0 ]] || fail 'Arranca desde la ISO oficial de Arch y ejecuta como root.'
  [[ -d /sys/firmware/efi ]] || fail 'El equipo no arrancó en modo UEFI. Reinicia la ISO en modo UEFI.'
  [[ "$(cat /sys/firmware/efi/fw_platform_size 2>/dev/null || echo 0)" == 64 ]] \
    || fail 'Este script solo soporta UEFI de 64 bits.'
  local cmd
  for cmd in lsblk findmnt blkid pacstrap genfstab arch-chroot mkfs.btrfs btrfs sha256sum awk sed; do
    command -v "$cmd" >/dev/null || fail "Falta '$cmd'. Usa una ISO oficial reciente de Arch Linux."
  done
  [[ -f "$ASSETS_DIR/grub-theme/theme.txt" ]] \
    || fail "No encuentro assets/grub-theme junto al script. Copia la carpeta completa del instalador, no solo install.sh."

  # Misma distribución de teclado al escribir la contraseña aquí que al iniciar sesión después.
  loadkeys "$CONSOLE_KEYMAP" 2>/dev/null || warn "No pude cargar el teclado '$CONSOLE_KEYMAP' en la ISO."

  info 'Sincronizando reloj...'
  timedatectl set-ntp true || true
  sleep 2

  info 'Comprobando internet (archlinux.org, AUR y GitHub)...'
  ping -c 1 -W 3 archlinux.org >/dev/null 2>&1 \
    || fail 'Sin internet. Conéctate con iwctl o nmcli antes de continuar.'
  curl -fsSI --max-time 10 https://aur.archlinux.org >/dev/null \
    || fail 'No se puede llegar a aur.archlinux.org (hace falta para Caelestia).'
  curl -fsSI --max-time 10 https://github.com >/dev/null \
    || fail 'No se puede llegar a github.com (hace falta para Caelestia).'

  sed -i 's/^#Color/Color/; s/^#ParallelDownloads.*/ParallelDownloads = 8/' /etc/pacman.conf
  pacman -Sy --noconfirm archlinux-keyring || warn 'No se pudo refrescar el llavero; continúo.'
}

# --------------------------- Elección de particiones -------------------------
choose_target() {
  clear || true
  info '=== Instalador Arch + Hyprland + Caelestia (dual boot con Windows) ==='
  warn 'No se reparticiona ningún disco. SOLO la partición ROOT que elijas será FORMATEADA.'
  warn 'Antes de seguir: ten a mano la clave de BitLocker (si la usas) y desactiva el Inicio rápido de Windows.'
  echo
  lsblk -d -e7,11 -o NAME,MODEL,SIZE,TYPE,TRAN
  echo
  read -r -p 'Disco donde está la partición destino (ej. nvme0n1 o /dev/sda): ' DISK
  [[ $DISK == /dev/* ]] || DISK="/dev/$DISK"
  [[ -b $DISK ]] || fail "No existe el dispositivo: $DISK"
  [[ "$(lsblk -dnro TYPE "$DISK")" == disk ]] || fail 'Debes introducir el disco completo (TYPE=disk), no una partición.'
  DISK=$(readlink -f "$DISK")

  echo
  info "Disco elegido: $DISK — capacidad: $(lsblk -dnro SIZE "$DISK")"
  lsblk -p -o NAME,SIZE,FSTYPE,LABEL,PARTTYPENAME,MOUNTPOINTS "$DISK"

  mapfile -t PARTITIONS < <(lsblk -nrpo NAME,TYPE "$DISK" | awk '$2 == "part" {print $1}')
  ((${#PARTITIONS[@]} > 0)) || fail 'No se encontraron particiones en ese disco. Crea primero una partición Linux con cfdisk.'

  echo
  local i p
  for i in "${!PARTITIONS[@]}"; do
    p=${PARTITIONS[$i]}
    printf '  [%d] %s | %s | %s | %s %s\n' "$((i+1))" "$p" "$(part_size "$p")" \
      "$(part_fs "$p")" "$(part_label "$p")" "$(part_tag "$p")"
  done

  echo
  read -r -p 'Número de la partición ROOT que se formateará: ' ROOT_INDEX
  [[ "$ROOT_INDEX" =~ ^[0-9]+$ ]] || fail 'Debes introducir un número de la lista.'
  ((ROOT_INDEX >= 1 && ROOT_INDEX <= ${#PARTITIONS[@]})) || fail 'Número de partición fuera de rango.'
  ROOT_PART=${PARTITIONS[$((ROOT_INDEX-1))]}

  if is_protected "$ROOT_PART"; then
    warn "¡Cuidado! $ROOT_PART parece ser una partición de Windows o la EFI: $(part_tag "$ROOT_PART")"
    read -r -p 'Si de verdad es una partición vacía/tuya para Arch, escribe FORMATEAR: ' SURE
    [[ "$SURE" == FORMATEAR ]] || { echo 'Cancelado. No se realizaron cambios.'; exit 0; }
  fi

  EFI_CANDIDATES=()
  for p in "${PARTITIONS[@]}"; do
    [[ "$p" != "$ROOT_PART" ]] || continue
    [[ "$(part_ptype "$p")" == "$ESP_GUID" ]] || continue
    EFI_CANDIDATES+=("$p")
  done
  ((${#EFI_CANDIDATES[@]} > 0)) || fail 'No hay partición EFI (ESP) en ese disco. Si Windows está en otro disco, ejecuta el script eligiendo ESE disco para la EFI.'

  echo
  info 'Particiones EFI candidatas (se usarán SIN formatear):'
  for i in "${!EFI_CANDIDATES[@]}"; do
    p=${EFI_CANDIDATES[$i]}
    printf '  [%d] %s | %s | %s\n' "$((i+1))" "$p" "$(part_size "$p")" "$(part_fs "$p")"
  done
  if ((${#EFI_CANDIDATES[@]} == 1)); then
    EFI_PART=${EFI_CANDIDATES[0]}
    info "Usaré la única EFI disponible: $EFI_PART"
  else
    read -r -p 'Número de la partición EFI que se usará (NO se formateará): ' EFI_INDEX
    [[ "$EFI_INDEX" =~ ^[0-9]+$ ]] || fail 'Debes introducir un número de la lista EFI.'
    ((EFI_INDEX >= 1 && EFI_INDEX <= ${#EFI_CANDIDATES[@]})) || fail 'Número EFI fuera de rango.'
    EFI_PART=${EFI_CANDIDATES[$((EFI_INDEX-1))]}
  fi

  [[ "$ROOT_PART" != "$EFI_PART" ]] || fail 'ROOT y EFI no pueden ser la misma partición.'
  if findmnt -rn -S "$ROOT_PART" >/dev/null; then fail "La partición raíz está montada: $ROOT_PART"; fi
  if findmnt -rn -S "$EFI_PART" >/dev/null; then fail "La partición EFI está montada: $EFI_PART. Desmóntala antes de continuar."; fi
  [[ "$(part_fs "$EFI_PART")" == vfat ]] || fail "La EFI $EFI_PART no es vfat."

  local root_bytes
  root_bytes=$(lsblk -bdnro SIZE "$ROOT_PART")
  ((root_bytes >= MIN_ROOT_GIB * 1024 * 1024 * 1024)) \
    || fail "La partición ROOT debe tener al menos ${MIN_ROOT_GIB} GiB (Hyprland + Caelestia compilan paquetes del AUR)."

  # ¿Hay un Windows en esa EFI? (montaje temporal de solo lectura)
  WIN_FOUND=0
  mkdir -p /run/teto-esp
  if mount -o ro "$EFI_PART" /run/teto-esp 2>/dev/null; then
    [[ -f /run/teto-esp/EFI/Microsoft/Boot/bootmgfw.efi ]] && WIN_FOUND=1
    umount /run/teto-esp
  fi
}

ask_user_data() {
  echo
  read -r -p 'Nombre de usuario nuevo (minúsculas/números/guion bajo): ' USERNAME
  [[ "$USERNAME" =~ ^[a-z_][a-z0-9_-]*$ ]] || fail 'Nombre de usuario no válido.'
  read -r -s -p 'Contraseña para el usuario: ' USER_PASS; echo
  read -r -s -p 'Repite la contraseña: ' USER_PASS_CONFIRM; echo
  [[ -n "$USER_PASS" && "$USER_PASS" == "$USER_PASS_CONFIRM" ]] || fail 'Contraseñas vacías o no coinciden.'
  read -r -p '¿Entrar a Hyprland automáticamente al arrancar, sin pedir contraseña? [s/N]: ' AUTO
  if [[ "$AUTO" == s || "$AUTO" == S ]]; then AUTOLOGIN=1; else AUTOLOGIN=0; fi
}

confirm_plan() {
  echo
  warn 'REVISA cuidadosamente estos datos:'
  echo "  Disco (no se reparticionará): $DISK — $(lsblk -dnro SIZE "$DISK")"
  echo "  ROOT (SE FORMATEARÁ Y SE BORRARÁ SU CONTENIDO): $ROOT_PART — $(part_size "$ROOT_PART")"
  echo "  EFI  (se monta en /efi; NO se formatea): $EFI_PART — $(part_size "$EFI_PART")"
  if [[ $WIN_FOUND -eq 1 ]]; then
    ok  '  Windows detectado en la EFI: se añadirá al menú de GRUB (chainload).'
  else
    warn '  No encontré el cargador de Windows en esa EFI: no se creará la entrada de Windows.'
  fi
  echo "  Usuario: $USERNAME · host: $HOSTNAME_NEW · zona horaria: $TIMEZONE · teclado: $HYPR_KB_LAYOUT"
  echo '  Todas las demás particiones se dejan intactas.'
  echo
  local answer
  read -r -p "Para confirmar, escribe exactamente $ROOT_PART : " answer
  [[ "$answer" == "$ROOT_PART" ]] || { echo 'Cancelado. No se realizaron cambios.'; exit 0; }
}

# ------------------------------ Instalación ----------------------------------
format_and_mount() {
  info "Formateando únicamente $ROOT_PART como Btrfs..."
  mkfs.btrfs -f -L ArchTeto "$ROOT_PART"
  mount "$ROOT_PART" "$MNT"; MOUNTED=1
  local sv
  for sv in @ @home @log @pkg; do btrfs subvolume create "$MNT/$sv"; done
  umount "$MNT"

  local opts='noatime,compress=zstd:3,space_cache=v2'
  mount -o "$opts,subvol=@" "$ROOT_PART" "$MNT"
  mkdir -p "$MNT"/{efi,home,var/log,var/cache/pacman/pkg}
  mount -o "$opts,subvol=@home" "$ROOT_PART" "$MNT/home"
  mount -o "$opts,subvol=@log"  "$ROOT_PART" "$MNT/var/log"
  mount -o "$opts,subvol=@pkg"  "$ROOT_PART" "$MNT/var/cache/pacman/pkg"

  # La EFI va en /efi (NO en /boot): los kernels viven en la raíz Btrfs y no llenan
  # la EFI pequeña (~100 MB) que Windows suele crear.
  mount -o umask=0077 "$EFI_PART" "$MNT/efi"
  local free_mb
  free_mb=$(df --output=avail -BM "$MNT/efi" | tail -n1 | tr -dc '0-9')
  ((free_mb >= 15)) || fail "La EFI solo tiene ${free_mb} MB libres; GRUB necesita ~15 MB."
}

install_base() {
  local ucode=() gpu=() gpu_info
  if grep -qi 'GenuineIntel' /proc/cpuinfo; then ucode=(intel-ucode)
  elif grep -qi 'AuthenticAMD' /proc/cpuinfo; then ucode=(amd-ucode); fi

  NVIDIA=0
  gpu_info=$(lspci -nn 2>/dev/null | grep -Ei 'vga|3d|display' || true)
  if grep -qi 'intel' <<<"$gpu_info"; then gpu+=(vulkan-intel intel-media-driver); fi
  if grep -Eqi '\b(amd|ati|radeon)\b|advanced micro' <<<"$gpu_info"; then gpu+=(vulkan-radeon); fi
  if grep -qi 'nvidia' <<<"$gpu_info"; then gpu+=(nvidia-open nvidia-utils); NVIDIA=1; fi
  if [[ $NVIDIA -eq 1 ]]; then
    warn 'GPU NVIDIA detectada: instalo nvidia-open (Turing/RTX 20 o más nuevas). Si tu tarjeta es anterior, cambia el driver después.'
  fi

  info 'Instalando Arch Linux, Hyprland y las dependencias de Caelestia (esto tarda)...'
  # Sin waybar/dunst/rofi/swaylock/swaybg: Caelestia trae su propia barra, notificaciones,
  # lanzador, bloqueo y fondo. Instalarlos a la vez provoca conflictos. Tampoco qt5ct/qt6ct
  # (chocan con qt5ct-kde/qt6ct-kde que usa Caelestia) ni seatd (logind ya hace ese trabajo).
  pacstrap -K "$MNT" \
    base base-devel linux linux-firmware "${ucode[@]}" btrfs-progs grub efibootmgr \
    ntfs-3g dosfstools sudo networkmanager zram-generator \
    hyprland xdg-desktop-portal-hyprland xdg-desktop-portal-gtk xorg-xwayland \
    qt5-wayland qt6-wayland polkit hyprpolkitagent foot firefox fish \
    greetd greetd-tuigreet \
    pipewire pipewire-alsa pipewire-pulse wireplumber pavucontrol playerctl brightnessctl \
    bluez bluez-utils \
    mesa "${gpu[@]}" \
    ttf-jetbrains-mono noto-fonts noto-fonts-cjk noto-fonts-emoji ttf-font-awesome \
    git curl nano

  genfstab -U "$MNT" >> "$MNT/etc/fstab"
}

configure_system() {
  info 'Configurando sistema base...'
  arch-chroot "$MNT" ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
  # Con dual boot, Windows espera el reloj de hardware en hora LOCAL. Se deja el RTC en local
  # para que ninguno de los dos sistemas desajuste la hora del otro.
  arch-chroot "$MNT" hwclock --systohc --localtime || warn 'No pude ajustar el reloj de hardware.'

  sed -i "s/^#\(${LOCALE_MAIN} UTF-8\)/\1/; s/^#\(en_US.UTF-8 UTF-8\)/\1/" "$MNT/etc/locale.gen"
  arch-chroot "$MNT" locale-gen
  printf 'LANG=%s\n' "$LOCALE_MAIN" > "$MNT/etc/locale.conf"
  printf 'KEYMAP=%s\n' "$CONSOLE_KEYMAP" > "$MNT/etc/vconsole.conf"
  printf '%s\n' "$HOSTNAME_NEW" > "$MNT/etc/hostname"
  cat > "$MNT/etc/hosts" <<HOSTS
127.0.0.1 localhost
::1       localhost
127.0.1.1 ${HOSTNAME_NEW}.localdomain ${HOSTNAME_NEW}
HOSTS

  sed -i 's/^#Color/Color/; s/^#ParallelDownloads.*/ParallelDownloads = 5/' "$MNT/etc/pacman.conf"
  sed -i "s/^#\?MAKEFLAGS=.*/MAKEFLAGS=\"-j$(nproc)\"/" "$MNT/etc/makepkg.conf"

  mkdir -p "$MNT/etc/systemd"
  cat > "$MNT/etc/systemd/zram-generator.conf" <<'ZRAM'
[zram0]
zram-size = min(ram / 2, 8192)
compression-algorithm = zstd
swap-priority = 100
ZRAM

  arch-chroot "$MNT" useradd -m -G wheel,video,audio,storage -s "$USER_SHELL" "$USERNAME"
  printf '%s:%s\n' "$USERNAME" "$USER_PASS" | arch-chroot "$MNT" chpasswd
  arch-chroot "$MNT" passwd -l root >/dev/null   # root bloqueado; se usa sudo
  printf '%%wheel ALL=(ALL:ALL) ALL\n' > "$MNT/etc/sudoers.d/10-wheel"
  chmod 440 "$MNT/etc/sudoers.d/10-wheel"
  arch-chroot "$MNT" visudo -cf /etc/sudoers.d/10-wheel >/dev/null

  arch-chroot "$MNT" systemctl enable NetworkManager bluetooth greetd fstrim.timer systemd-timesyncd
}

# -------------------------- GRUB bonito + Windows ----------------------------
setup_grub() {
  info 'Instalando GRUB en la EFI compartida (sin formatearla) y creando el menú de arranque...'
  local cfg="$MNT/etc/default/grub" theme_dir="$MNT/boot/grub/themes/teto"
  local theme_ok=1 font_reg font_bold esp_uuid cmdline

  set_grub() {  # clave valor-ya-entrecomillado-si-hace-falta
    if grep -q "^#\?$1=" "$cfg"; then sed -i "s|^#\?$1=.*|$1=$2|" "$cfg"; else printf '%s=%s\n' "$1" "$2" >> "$cfg"; fi
  }

  cmdline='quiet loglevel=3'
  if [[ $NVIDIA -eq 1 ]]; then cmdline="$cmdline nvidia_drm.modeset=1"; fi

  # --- tema ---
  install -d "$theme_dir"
  cp -r "$ASSETS_DIR/grub-theme/." "$theme_dir/"
  font_reg=$(arch-chroot "$MNT" fc-match -f '%{file}' 'JetBrains Mono:style=Regular') || font_reg=''
  font_bold=$(arch-chroot "$MNT" fc-match -f '%{file}' 'JetBrains Mono:style=Bold') || font_bold=''
  if [[ -n $font_reg && -n $font_bold ]]; then
    arch-chroot "$MNT" grub-mkfont -n Teto -s 18 -o /boot/grub/themes/teto/teto-regular-18.pf2 "$font_reg" \
    && arch-chroot "$MNT" grub-mkfont -n Teto -s 22 -o /boot/grub/themes/teto/teto-regular-22.pf2 "$font_reg" \
    && arch-chroot "$MNT" grub-mkfont -n Teto -s 22 -o /boot/grub/themes/teto/teto-bold-22.pf2 "$font_bold" \
    && arch-chroot "$MNT" grub-mkfont -n Teto -s 26 -o /boot/grub/themes/teto/teto-bold-26.pf2 "$font_bold" \
    || theme_ok=0
  else
    theme_ok=0
  fi

  set_grub GRUB_TIMEOUT "$GRUB_TIMEOUT_SECS"
  set_grub GRUB_TIMEOUT_STYLE menu
  set_grub GRUB_DISTRIBUTOR '"Arch"'
  set_grub GRUB_CMDLINE_LINUX_DEFAULT "\"$cmdline\""
  set_grub GRUB_GFXMODE auto
  set_grub GRUB_GFXPAYLOAD_LINUX keep
  set_grub GRUB_DISABLE_OS_PROBER true   # Windows se añade a mano (más fiable que os-prober en chroot)
  if [[ $theme_ok -eq 1 ]]; then
    set_grub GRUB_THEME '"/boot/grub/themes/teto/theme.txt"'
    set_grub GRUB_TERMINAL_OUTPUT gfxterm
  else
    warn 'No pude generar las fuentes del tema; GRUB quedará con el aspecto por defecto.'
  fi
  # Nota: NO se usa GRUB_DEFAULT=saved/GRUB_SAVEDEFAULT: GRUB no escribe de forma fiable en Btrfs.

  # --- Windows (chainload al Boot Manager de la EFI) ---
  if [[ -f "$MNT/efi/EFI/Microsoft/Boot/bootmgfw.efi" ]]; then
    esp_uuid=$(blkid -s UUID -o value "$EFI_PART")
    {
      # shellcheck disable=SC2016  # $0 debe quedar literal en el archivo generado
      printf '%s\n' '#!/bin/sh' 'exec tail -n +3 $0'
      cat <<WINENTRY
menuentry "${WINDOWS_TITLE}" --class windows --class os {
    insmod part_gpt
    insmod fat
    insmod chain
    search --no-floppy --fs-uuid --set=root ${esp_uuid}
    chainloader /EFI/Microsoft/Boot/bootmgfw.efi
}
WINENTRY
    } > "$MNT/etc/grub.d/15_teto_windows"
    chmod 755 "$MNT/etc/grub.d/15_teto_windows"
  else
    warn 'bootmgfw.efi no está en la EFI: GRUB se instala sin entrada de Windows.'
  fi

  # --- Firmware / Reiniciar / Apagar con iconos propios ---
  cat > "$MNT/etc/grub.d/41_teto_extras" <<'GRUBEXTRAS'
#!/bin/sh
if [ -e /sys/firmware/efi/efivars/OsIndicationsSupported-8be4df61-93ca-11d2-aa0d-00e098032b8c ]; then
cat <<'EOF'
menuentry "Configuración de firmware UEFI" --class efi {
    fwsetup
}
EOF
fi
cat <<'EOF'
menuentry "Reiniciar" --class restart {
    reboot
}
menuentry "Apagar" --class shutdown {
    halt
}
EOF
GRUBEXTRAS
  chmod 755 "$MNT/etc/grub.d/41_teto_extras"
  # Evita la entrada duplicada y sin icono de "UEFI Firmware Settings".
  if [[ -e "$MNT/etc/grub.d/30_uefi-firmware" ]]; then chmod -x "$MNT/etc/grub.d/30_uefi-firmware"; fi

  arch-chroot "$MNT" grub-install --target=x86_64-efi --efi-directory=/efi --bootloader-id=Arch --recheck
  arch-chroot "$MNT" grub-mkconfig -o /boot/grub/grub.cfg

  if [[ -f "$MNT/etc/grub.d/15_teto_windows" ]]; then
    if grep -q 'bootmgfw.efi' "$MNT/boot/grub/grub.cfg"; then
      ok 'Entrada de Windows creada en GRUB.'
    else
      warn 'No encuentro la entrada de Windows en grub.cfg; revisa /etc/grub.d/15_teto_windows.'
    fi
  fi
  info 'Entradas de arranque UEFI actuales:'
  efibootmgr || true
}

# ------------------------------ Login (greetd) -------------------------------
setup_greetd() {
  info 'Configurando greetd (pantalla de inicio de sesión)...'
  local hypr_cmd=Hyprland
  # Hyprland reciente avisa si se lanza "Hyprland" a pelo; start-hyprland es el lanzador correcto.
  if arch-chroot "$MNT" sh -c 'command -v start-hyprland >/dev/null 2>&1'; then hypr_cmd=start-hyprland; fi

  mkdir -p "$MNT/etc/greetd"
  {
    cat <<GREETD
[terminal]
vt = 1

[default_session]
command = "tuigreet --time --asterisks --remember --cmd ${hypr_cmd} --theme 'border=red;title=lightred;prompt=lightred;input=white;text=white;time=red;action=red;button=lightred;container=black'"
user = "greeter"
GREETD
    if [[ $AUTOLOGIN -eq 1 ]]; then
      cat <<AUTOLOGIN_BLOCK

[initial_session]
command = "${hypr_cmd}"
user = "${USERNAME}"
AUTOLOGIN_BLOCK
    fi
  } > "$MNT/etc/greetd/config.toml"

  # tuigreet necesita poder escribir aquí para recordar el usuario.
  arch-chroot "$MNT" install -d -o greeter -g greeter -m 0755 /var/cache/tuigreet || warn 'No pude preparar /var/cache/tuigreet.'
}

# ----------------------- Fondos y ajustes de usuario -------------------------
setup_user_env() {
  local home="$MNT/home/$USERNAME" dst
  info 'Copiando tus fondos de pantalla SIN modificarlos...'
  if compgen -G "$WALL_SRC/*" >/dev/null; then
    dst="$home/Pictures/Wallpapers"
    install -d "$dst"
    cp -p --no-preserve=ownership "$WALL_SRC"/* "$dst"/
    ( cd "$WALL_SRC" && sha256sum -- * ) > /tmp/teto-wall.sha256
    ( cd "$dst" && sha256sum -c --quiet /tmp/teto-wall.sha256 ) \
      || fail 'Las imágenes copiadas no coinciden con las originales (sha256). Abortando.'
    ok "Fondos copiados byte a byte ($(wc -l < /tmp/teto-wall.sha256) archivos verificados)."
    if [[ ! -f "$dst/$DEFAULT_WALLPAPER" ]]; then
      warn "No existe $DEFAULT_WALLPAPER en wallpapers/; no se aplicará fondo inicial automáticamente."
    fi
  else
    warn "No hay carpeta wallpapers/ junto al script: se omite la copia de fondos."
  fi

  # Primer inicio de sesión: aplica fondo + esquema dinámico (colores sacados del fondo).
  install -d "$home/.local/bin" "$home/.config/caelestia"
  cat > "$home/.local/bin/teto-first-login" <<'FIRSTLOGIN'
#!/usr/bin/env bash
# Aplica el fondo y el esquema de colores de Caelestia la primera vez que inicias sesión.
flag="$HOME/.local/state/teto-first-login.done"
[[ -e "$flag" ]] && exit 0
wall="$HOME/Pictures/Wallpapers/@DEFAULT_WALLPAPER@"
[[ -f "$wall" ]] || exit 0
command -v caelestia >/dev/null 2>&1 || exit 0
for _ in $(seq 1 60); do pgrep -f quickshell >/dev/null && break; sleep 1; done
sleep 4
if caelestia wallpaper -f "$wall" && caelestia scheme set -n dynamic; then
  mkdir -p "$(dirname "$flag")"
  touch "$flag"
fi
FIRSTLOGIN
  sed -i "s|@DEFAULT_WALLPAPER@|$DEFAULT_WALLPAPER|" "$home/.local/bin/teto-first-login"
  chmod 755 "$home/.local/bin/teto-first-login"

  # Ajustes propios en el archivo de usuario de las dots (no se tocan las dots en sí).
  if ! grep -qs 'teto-installer' "$home/.config/caelestia/hypr-user.conf"; then
    cat >> "$home/.config/caelestia/hypr-user.conf" <<HYPRUSER

# --- teto-installer ---
input {
    kb_layout = ${HYPR_KB_LAYOUT}
}
exec-once = /home/${USERNAME}/.local/bin/teto-first-login
exec-once = /usr/lib/hyprpolkitagent/hyprpolkitagent
# --- fin teto-installer ---
HYPRUSER
  fi
}

# ------------------------- yay + Caelestia (como usuario) --------------------
install_caelestia() {
  info 'Instalando yay y Caelestia. Compila paquetes del AUR: puede tardar 20-60 minutos...'
  install -d "$MNT/opt/teto-install"
  cat > "$MNT/opt/teto-install/user-phase.sh" <<'USERPHASE'
#!/usr/bin/env bash
set -Eeuo pipefail
export MAKEFLAGS="-j$(nproc)"
mkdir -p "$HOME/.cache/teto-build" "$HOME/.local/share"

if ! command -v yay >/dev/null 2>&1; then
  rm -rf "$HOME/.cache/teto-build/yay-bin"
  git clone --depth 1 https://aur.archlinux.org/yay-bin.git "$HOME/.cache/teto-build/yay-bin"
  ( cd "$HOME/.cache/teto-build/yay-bin" && makepkg -si --noconfirm )
fi

if [[ -d "$HOME/.local/share/caelestia/.git" ]]; then
  git -C "$HOME/.local/share/caelestia" pull --ff-only || true
else
  git clone --depth 1 https://github.com/caelestia-dots/caelestia.git "$HOME/.local/share/caelestia"
fi

# Instalador oficial de las dots (es un script de fish). No muevas ni borres esa carpeta después:
# instala enlaces simbólicos hacia ella.
fish "$HOME/.local/share/caelestia/install.fish" --noconfirm --aur-helper=yay

rm -rf "$HOME/.cache/teto-build"
USERPHASE
  chmod 755 "$MNT/opt/teto-install/user-phase.sh"
  cp "$MNT/opt/teto-install/user-phase.sh" "$MNT/home/$USERNAME/terminar-caelestia.sh"

  # sudo sin contraseña SOLO durante este paso; cleanup() lo borra pase lo que pase.
  printf '%s ALL=(ALL) NOPASSWD: ALL\n' "$USERNAME" > "$MNT/etc/sudoers.d/90-teto-temp-nopasswd"
  chmod 440 "$MNT/etc/sudoers.d/90-teto-temp-nopasswd"
  arch-chroot "$MNT" chown -R "$USERNAME:$USERNAME" "/home/$USERNAME"

  CAELESTIA_OK=0
  if arch-chroot "$MNT" runuser -l "$USERNAME" -c 'bash /opt/teto-install/user-phase.sh'; then
    CAELESTIA_OK=1
  fi
  rm -f "$MNT/etc/sudoers.d/90-teto-temp-nopasswd"

  if [[ $CAELESTIA_OK -eq 1 ]]; then
    ok 'Caelestia instalado.'
    rm -f "$MNT/home/$USERNAME/terminar-caelestia.sh"
  else
    warn 'Caelestia NO terminó de instalarse (red/AUR). El sistema base sí quedó listo.'
    warn "Tras reiniciar, inicia sesión y ejecuta:  bash ~/terminar-caelestia.sh"
  fi
}

# --------------------------------- Final -------------------------------------
finish() {
  arch-chroot "$MNT" chown -R "$USERNAME:$USERNAME" "/home/$USERNAME"
  sleep 1
  cp "$LOG" "$MNT/var/log/teto-install.log" 2>/dev/null || true
  rm -rf "$MNT/opt/teto-install"
  trap - EXIT
  umount -R "$MNT"
  MOUNTED=0

  echo
  ok 'Instalación completada.'
  echo "  Arranque: GRUB con tema rojo/negro → Arch Linux / ${WINDOWS_TITLE}."
  if [[ $AUTOLOGIN -eq 1 ]]; then
    echo '  Entrarás directo a Hyprland (inicio automático activado).'
  else
    echo "  Inicia sesión como '$USERNAME' en la pantalla de greetd; arranca Hyprland con Caelestia."
  fi
  echo '  Registro de la instalación: /var/log/teto-install.log'
  echo
  warn 'En Windows (una sola vez): desactiva el Inicio rápido (powercfg /h off) para poder leer NTFS desde Linux.'
  warn 'Si una actualización de Windows cambia el orden de arranque:  sudo efibootmgr  (y  -o  para reordenar).'
  echo
  read -r -p '¿Reiniciar ahora? [s/N]: ' REBOOT_ANSWER
  if [[ "$REBOOT_ANSWER" == s || "$REBOOT_ANSWER" == S ]]; then reboot; fi
}

main() {
  preflight
  choose_target
  ask_user_data
  confirm_plan
  exec > >(tee -a "$LOG") 2>&1     # a partir de aquí se guarda todo en el registro
  format_and_mount
  install_base
  configure_system
  setup_grub
  setup_greetd
  install_caelestia
  setup_user_env       # después de las dots, para no interferir con install.fish
  finish
}

main "$@"

main "$@"
