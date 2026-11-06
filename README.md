# Teto Installer — instalación en una partición

Instalador interactivo para Arch Linux en modo UEFI. Permite elegir un disco, muestra su capacidad y todas sus particiones, y solicita seleccionar una partición raíz. **No crea ni modifica la tabla de particiones del disco.**

## Qué hace

- Muestra la capacidad del disco elegido y una lista de sus particiones, tamaños, sistemas de archivos y puntos de montaje.
- Instala solo en la partición ROOT que selecciones; esa partición se formatea como Btrfs y se borra su contenido.
- Permite elegir una partición EFI `vfat` del mismo disco. La EFI se monta en `/boot` y **no se formatea**, aunque GRUB escribirá sus propios archivos allí.
- Antes de escribir, muestra un resumen y exige responder `s`; `n` o cualquier otra respuesta cancela.
- Instala Arch, NetworkManager y Hyprland. No instala automáticamente paquetes de AUR ni Caelestia.

## Requisitos

- Arrancar una ISO oficial reciente de Arch Linux en modo UEFI.
- Internet y conexión eléctrica estable.
- Una partición raíz de al menos 20 GiB (40 GiB sirve para una instalación básica).
- Una partición EFI `vfat` existente en el mismo disco.
- Copia de seguridad de cualquier dato que quieras conservar.

## Uso

En la terminal de la ISO, como root:

```bash
curl -fsSL https://raw.githubusercontent.com/Ranijuan/teto-installer/main/install.sh -o /tmp/teto-installer.sh && bash /tmp/teto-installer.sh
```

El script te pedirá el disco (por ejemplo `/dev/nvme0n1`), mostrará su capacidad y particiones, y luego permitirá seleccionar ROOT y EFI por número. Comprueba con atención cada selección. Para la raíz, `/dev/nvme0n1p4` sería una entrada de partición; **solo elige esa si verificaste que es la partición de 40 GiB que quieres borrar**. Selecciona también la EFI correcta (normalmente una partición pequeña `vfat`, por ejemplo `/dev/nvme0n1p1`).

La instalación solo empieza si respondes `s` al resumen. Si respondes `n`, se cancela.

## Advertencias

- ROOT se formatea sin posibilidad de recuperación sencilla. No continúes si contiene datos que quieras conservar.
- La EFI no se formatea, pero GRUB añade archivos de arranque a ella. Al compartirla con Windows, conserva los archivos existentes; aun así, verifica que sea la EFI correcta y que haya espacio libre.
- El instalador no puede garantizar compatibilidad con todas las configuraciones de firmware, controladores o particionados. Revisa el script antes de ejecutarlo.
- Es un instalador personal, no un sustituto de la guía oficial de Arch.
