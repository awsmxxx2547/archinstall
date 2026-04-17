#!/bin/bash

echo "Checking internet connectivity..."
if ping -c 3 8.8.8.8 &> /dev/null; then
    echo "Internet connection is active."
else
    echo "No internet connection detected. Please connect to the internet and try again."
    exit 1
fi

read_password() {
  local prompt="$1"
  local password=""
  while true; do
    echo -n "$prompt"
    read -s password
    echo
    if [[ -z "$password" ]]; then
      echo "Password cannot be empty. Please try again."
    else
      break
    fi
  done
  REPLY="$password"
}

set -e

# Ускоряем pacman
sed -i '/^#Color/s/^#//' /etc/pacman.conf
sed -i 's/^#\?\s*ParallelDownloads\s*=.*/ParallelDownloads = 100/' /etc/pacman.conf
grep -q '^ParallelDownloads' /etc/pacman.conf || echo 'ParallelDownloads = 100' >> /etc/pacman.conf
sed -i '/#DisableSandbox/a\ILoveCandy' /etc/pacman.conf

# Настройки диска и LVM
DISK="/dev/nvme0n1"
EFI="${DISK}p1"
LVM_PV="${DISK}p2"
VG_NAME="vg0"

TIMEZONE="Europe/Kiev"
LOCALE="en_US.UTF-8"

read -p "Enter hostname: " HOSTNAME
read -p "Enter username: " USERNAME

read_password "Enter root password: "
ROOTPASS="$REPLY"
read_password "Enter user password: "
USERPASS="$REPLY"

read -p "Create separate /home partition? [Y/n]: " CREATE_HOME
read -p "Enter root (/) size in GiB (e.g., 40): " ROOT_SIZE
RAM_SIZE=$(grep MemTotal /proc/meminfo | awk '{print int($2 / 1024 / 1024 + 1)}')  # RAM in GiB

echo "Partitioning $DISK..."
sgdisk -Z "$DISK"
# Создаем EFI раздел (512MB)
sgdisk -n 1:0:+512M -t 1:ef00 "$DISK"
# Всё оставшееся место отдаем под LVM (код 8e00)
sgdisk -n 2:0:0 -t 2:8e00 "$DISK"

echo "Configuring LVM..."
pvcreate -f "$LVM_PV"
vgcreate "$VG_NAME" "$LVM_PV"

# Создаем логические тома
lvcreate -L "${RAM_SIZE}G" "$VG_NAME" -n swap
lvcreate -L "${ROOT_SIZE}G" "$VG_NAME" -n root

if [[ "$CREATE_HOME" =~ ^[Yy]$ || "$CREATE_HOME" == "" ]]; then
    # Отдаем под /home все 100% оставшегося свободного места в группе
    lvcreate -l 100%FREE "$VG_NAME" -n home
    USE_HOME=true
else
    USE_HOME=false
fi

echo "Formatting partitions..."
mkfs.fat -F32 "$EFI"
mkswap "/dev/$VG_NAME/swap"
# Форматируем в XFS
mkfs.xfs -f "/dev/$VG_NAME/root"

if $USE_HOME; then
    mkfs.xfs -f "/dev/$VG_NAME/home"
fi

echo "Mounting partitions..."
mount "/dev/$VG_NAME/root" /mnt

# Правильное монтирование EFI (один раз)
mkdir -p /mnt/boot/efi
mount "$EFI" /mnt/boot/efi

swapon "/dev/$VG_NAME/swap"

if $USE_HOME; then
    mkdir /mnt/home
    mount "/dev/$VG_NAME/home" /mnt/home
fi

echo "Installing base system (added lvm2 and xfsprogs)..."
pacstrap /mnt base base-devel linux linux-firmware vim iwd sudo amd-ucode grub efibootmgr dhcpcd lvm2 xfsprogs

echo "Generating fstab..."
genfstab -U /mnt >> /mnt/etc/fstab

echo "Entering chroot environment..."
arch-chroot /mnt /bin/bash <<EOF
set -e

sed -i '/^#Color/s/^#//' /etc/pacman.conf
sed -i 's/^#\?\s*ParallelDownloads\s*=.*/ParallelDownloads = 100/' /etc/pacman.conf
grep -q '^ParallelDownloads' /etc/pacman.conf || echo 'ParallelDownloads = 100' >> /etc/pacman.conf
sed -i '/#DisableSandbox/a\ILoveCandy' /etc/pacman.conf

ln -sf /usr/share/zoneinfo/Europe/Kiev /etc/localtime
hwclock --systohc

echo "$HOSTNAME" > /etc/hostname
echo -e "127.0.0.1   localhost\n::1         localhost\n127.0.1.1   $HOSTNAME.localdomain $HOSTNAME" > /etc/hosts

sed -i '/^#en_US.UTF-8 UTF-8/s/^#//' /etc/locale.gen
sed -i '/^#ru_RU.UTF-8 UTF-8/s/^#//' /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf

echo "root:$ROOTPASS" | chpasswd

useradd -m $USERNAME
echo "$USERNAME:$USERPASS" | chpasswd
usermod -aG wheel,audio,video,optical,storage $USERNAME

sed -i '/^# %wheel ALL=(ALL:ALL) ALL/s/^# //' /etc/sudoers
sed -i '/^\[multilib\]/,/^Include/ s/^#//' /etc/pacman.conf

pacman -S --noconfirm reflector networkmanager

systemctl enable NetworkManager

echo "Configuring initramfs for LVM..."
# Вставляем хук lvm2 между block и filesystems для корректной загрузки
sed -i 's/\bblock filesystems\b/block lvm2 filesystems/g' /etc/mkinitcpio.conf
mkinitcpio -P

echo "Installing GRUB bootloader..."
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB --recheck
grub-mkconfig -o /boot/grub/grub.cfg

echo "Installation complete!"
EOF
