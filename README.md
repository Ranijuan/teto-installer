ARCH + HYPRLAND + CAELESTIA · dual boot con Windows · estilo Teto
=================================================================

Qué hay en esta carpeta
  install.sh      el instalador (lo único que ejecutas)
  assets/         tema de GRUB (fondo, iconos, barra de selección, theme.txt)
  wallpapers/     tus 34 imágenes, SIN modificar (se copian tal cual a ~/Pictures/Wallpapers)

Antes de empezar (en Windows)
  1. Si usas BitLocker / Cifrado de dispositivo: guarda la clave de recuperación.
  2. Desactiva el Inicio rápido (como administrador:  powercfg /h off).
  3. Reduce C: en "Administración de discos" y deja espacio SIN ASIGNAR (mínimo 25 GiB, mejor 40+).

Desde la ISO oficial de Arch (arrancada en modo UEFI)
  1. Conéctate a internet (Wi-Fi:  iwctl).
  2. Crea una partición Linux en el espacio libre, sin tocar la EFI ni las de Windows:
         cfdisk /dev/nvme0n1        (cambia el disco por el tuyo)
  3. Monta el USB que lleva esta carpeta. NO uses /mnt (el instalador lo usa como destino):
         mkdir /root/usb && mount /dev/sdX1 /root/usb
         bsdtar -xf /root/usb/arch-teto-installer.zip -C /root
         cd /root/arch-teto-installer
  4. Ejecuta:
         bash install.sh

Ajustes opcionales (variables de entorno), por ejemplo:
  TIMEZONE=America/Mexico_City HYPR_KB_LAYOUT=latam bash install.sh
  Valores por defecto: TIMEZONE=America/Bogota, LOCALE_MAIN=es_CO.UTF-8,
  CONSOLE_KEYMAP=la-latin1, HYPR_KB_LAYOUT=latam, HOSTNAME_NEW=teto-arch,
  DEFAULT_WALLPAPER=IMG_3004.jpg, WINDOWS_TITLE=Windows

Si Caelestia no termina de instalarse (red / AUR), el sistema base queda listo.
Tras reiniciar, inicia sesión y ejecuta:   bash ~/terminar-caelestia.sh

Registro de la instalación: /var/log/teto-install.log (en el sistema nuevo)
