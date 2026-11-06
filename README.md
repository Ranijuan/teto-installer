# Teto Installer

Este repositorio contiene una versión mejorada del instalador para Arch Linux con Hyprland + Teto.

Importante:
- El script elimina el contenido del disco que elijas.
- Debes ejecutarlo desde la ISO de instalación de Arch, como root.
- Solo es seguro si sabes qué disco está seleccionando.
- Se recomienda revisar `lsblk` antes de arrancar la instalación.

Requisitos:
- ISO de Arch Linux arrancada en vivo.
- Conexión a internet.
- Usuario root.

Instalación rápida:

```bash
curl -fsSL https://raw.githubusercontent.com/Ranijuan/teto-installer/main/install.sh -o /tmp/teto-installer.sh && chmod +x /tmp/teto-installer.sh && bash /tmp/teto-installer.sh
```

Revisión previa del disco:

```bash
lsblk
```

Luego, en la terminal, escribe el disco objetivo (por ejemplo `/dev/nvme0n1`) y confirma exactamente:

```bash
TETO-ERASE
```

Esto hará una instalación automática con:
- GPT
- EFI
- Btrfs con subvolúmenes
- Archinstall
- Hyprland + Teto style setup
- Wallpaper + atajos básicos

Advertencia:
- No lo ejecutes sobre un disco con datos importantes.
- Si tu equipo tiene Windows y quieres conservarlo, revisa bien el disco y el particionado.

Este script está pensado para uso personal en pruebas controladas y entornos de instalación de Arch.
