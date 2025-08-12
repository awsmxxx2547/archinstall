#!/bin/bash

echo "Checking internet connectivity..."
if ping -c 3 8.8.8.8 &> /dev/null; then
    echo "Internet connection is active."
else
    echo "No internet connection detected. Please connect to the internet and try again."
    exit 1
fi

# Check UEFI mode
if [ ! -d /sys/firmware/efi ]; then
    echo "Error: System is not booted in UEFI mode. Cannot install systemd-boot."
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

sed -i '/^#Color/s/^#//' /etc/pacman.conf
sed -i 's/^#\?\s*ParallelDownloads\s*=.*/ParallelDownloads = 100/' /etc/pacman.conf
grep -q '^ParallelDownloads' /etc/pacman.conf || echo 'ParallelDownloads = 100' >> /etc/pacman.conf
sed -i '/#DisableSandbox/a\ILoveCandy' /etc/pacman.conf

# Disk selection
echo "Available disks:"
lsblk -dpno NAME,SIZE | grep -E "/dev/(sd|nvme|vd)"
echo
read -p "Enter the disk to install Arch Linux on (e.g., /dev/nvme0n1): " DISK

# Double-check before wiping
read -p "WARNING: All data on $DISK will be erased! Type 'YES' to continue: " CONFIRM
if [[ "$CONFIRM" != "YES" ]]; then
    echo "Aborted."
    exit 1
fi

EFI="${DISK}p1"
SWAP="${DISK}p2"
ROOT="${DISK}p3"
HOME="${DISK}p4"

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
sgdisk -n 1:0:+512M -t 1:ef00 "$DISK"
sgdisk -n 2:0:+${RAM_SIZE}G -t 2:8200 "$DISK"
sgdisk -n 3:0:+${ROOT_SIZE}G -t 3:8300 "$DISK"

if [[ "$CREATE_HOME" =~ ^[Yy]$ || "$CREATE_HOME" == "" ]]; then
    sgdisk -n 4:0:0 -t 4:8300 "$DISK"
    USE_HOME=true
else
    USE_HOME=false
fi

echo "Formatting partitions..."
mkfs.fat -F32 -n EFI "$EFI"
mkswap "$SWAP"
mkfs.ext4 "$ROOT"

if $USE_HOME; then
    mkfs.ext4 "$HOME"
fi

echo "Mounting partitions..."
mount "$ROOT" /mnt
mkdir -p /mnt/boot/efi
mount "$EFI" /mnt/boot/efi
swapon "$SWAP"

if $USE_HOME; then
    mkdir /mnt/home
    mount "$HOME" /mnt/home
fi

echo "Installing base system..."
pacstrap /mnt base base-devel linux linux-firmware vim iwd sudo amd-ucode efibootmgr dhcpcd

genfstab -U /mnt >> /mnt/etc/fstab

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

bootctl --path=/boot/efi install
cat > /boot/loader/loader.conf <<LOADER
default arch
timeout 0
editor no
LOADER

UUID=$(blkid -s UUID -o value $ROOT)

cat > /boot/loader/entries/arch.conf <<BOOT
title   🚀My Super OS
linux   /vmlinuz-linux
initrd  /amd-ucode.img
initrd  /initramfs-linux.img
options root=UUID=$UUID rw
BOOT
EOF
