# Teto Installer

Este repositorio contiene una versión segura del instalador para Arch Linux con Hyprland + Teto.

Qué hace esta versión:
- No borra el disco completo.
- Solo formatea la partición raíz que tú elijas.
- Usa una partición EFI existente o una que indiques.
- Monta Btrfs en la partición seleccionada.
- Instala Arch sobre esa partición sin tocar el resto del disco.

Advertencia importante:
- Esta versión sí formatea la partición elegida.
- Antes de empezar, revisa `lsblk` para asegurarte de que la partición es la correcta.
- Si no sabes qué partición es la raíz, no la uses.

Requisitos:
- ISO de Arch Linux arrancada en vivo.
- Conexión a internet.
- Acceso como root.

Comando rápido:

```bash
curl -fsSL https://raw.githubusercontent.com/Ranijuan/teto-installer/main/install.sh -o /tmp/teto-installer.sh && chmod +x /tmp/teto-installer.sh && bash /tmp/teto-installer.sh
```

Antes de iniciar:

```bash
lsblk -o NAME,SIZE,FSTYPE,TYPE,MOUNTPOINTS
```

Si tu partición raíz es, por ejemplo:

```bash
/dev/nvme0n1p4
```

y la EFI es:

```bash
/dev/nvme0n1p1
```

entonces escribe exactamente:

```bash
TETO-PART
```

para confirmar.

Esto hace:
- Btrfs en `/dev/nvme0n1p4`
- Montaje en `/mnt`
- Uso de `/dev/nvme0n1p1` como EFI
- Instalar Arch con Hyprland + Teto

IMPORTANTE:
- No ejecutes esto sobre una partición con datos importantes.
- Esta versión está pensada para instalar Arch en una partición específica y segura, no para borrar todo el disco.

