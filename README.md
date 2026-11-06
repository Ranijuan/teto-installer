# Teto Installer

Este repositorio contiene un instalador automático para Arch Linux con Hyprland + Teto.

Importante:
- El script detecta un disco y crea particiones automáticamente.
- Formatea y usa Btrfs.
- Asume que lo ejecutas desde el entorno de instalación de Arch y que quieres instalar sobre el disco principal.
- Revisa el código antes de ejecutarlo.

Instalación rápida desde una terminal:

```bash
curl -fsSL https://raw.githubusercontent.com/Ranijuan/teto-installer/main/install.sh -o /tmp/teto-installer.sh && chmod +x /tmp/teto-installer.sh && bash /tmp/teto-installer.sh
```

O directamente:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Ranijuan/teto-installer/main/install.sh)
```

Si quieres ejecutarlo localmente desde el repositorio:

```bash
chmod +x install.sh
sudo ./install.sh
```

Se solicita escribir `TETO` para confirmar la instalación.

Este proyecto está pensado para uso personal y prueba en máquinas controladas.
