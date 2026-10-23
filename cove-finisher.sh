#!/bin/bash
# cove-finisher.sh — THE LAST RUNG (Core, 2026-10-23)
# The system is BUILT. This only: installs the kernel if missing, builds initramfs,
# makes keys, signs, wires vest+ESP, installs re-sign hook, requests MOK.
# NEVER re-runs pacstrap. DNS fixed INSIDE the target where it matters.
set -euo pipefail

echo "=============================================="
echo "  COVE FINISHER — start $(date)"
echo "=============================================="

# --- 0. host tools ---
command -v arch-chroot >/dev/null || { echo "FATAL: run first: sudo apt-get install -y arch-install-scripts"; exit 1; }
command -v openssl >/dev/null || { echo "FATAL: openssl missing on live session"; exit 1; }

# --- 1. disk discovery (label-based, proven) ---
RAFTNAME=$(lsblk -rno NAME,LABEL | awk '$2=="OMARCHYRAFT"{print $1}' | head -1)
[ -n "$RAFTNAME" ] || { echo "FATAL: OMARCHYRAFT not found"; lsblk; exit 1; }
REALDISK=$(lsblk -rno NAME,PKNAME | awk -v r="$RAFTNAME" '$1==r{print $2}' | head -1 | tr -d ' ')
[ -n "$REALDISK" ] || { echo "FATAL: parent disk of raft not found"; exit 1; }
DISK="/dev/$REALDISK"
echo "disk: $DISK (raft: $RAFTNAME)"

# --- 2. heal any vanished device nodes ---
for disknode in $(lsblk -rno NAME,MAJ:MIN "$DISK" 2>/dev/null | awk -F'[: ]' '{print $1":"$2":"$3}'); do
  nm=$(echo "$disknode" | cut -d: -f1); mj=$(echo "$disknode" | cut -d: -f2); mn=$(echo "$disknode" | cut -d: -f3)
  [ -e "/dev/$nm" ] || { mknod "/dev/$nm" b "$mj" "$mn" 2>/dev/null || true; echo "healed node: /dev/$nm"; }
done

# --- 3. mounts ---
mkdir -p /mnt/raft /mnt/omarchy
mountpoint -q /mnt/raft || mount /dev/disk/by-label/OMARCHYRAFT /mnt/raft
mountpoint -q /mnt/omarchy || mount /dev/disk/by-label/OMARCHY /mnt/omarchy
UUID=$(blkid -s UUID -o value /dev/disk/by-label/OMARCHY)
echo "target mounted, UUID: $UUID"

# --- 4. fstab + hostname (idempotent) ---
grep -q "UUID=$UUID" /mnt/omarchy/etc/fstab 2>/dev/null || echo "UUID=$UUID / btrfs defaults,noatime 0 1" > /mnt/omarchy/etc/fstab
echo "cove" > /mnt/omarchy/etc/hostname
echo "fstab + hostname set"

# --- 5. kernel: install ONLY if missing ---
if [ -f /mnt/omarchy/boot/vmlinuz-linux ]; then
  echo "kernel present — skipping install"
else
  echo "kernel missing — fixing DNS + mirrors INSIDE target, then installing"
  printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > /mnt/omarchy/etc/resolv.conf
  sed -i 's/^#Server/Server/' /mnt/omarchy/etc/pacman.d/mirrorlist
  arch-chroot /mnt/omarchy pacman-key --init 2>/dev/null || true
  arch-chroot /mnt/omarchy pacman-key --populate archlinux 2>/dev/null || true
  echo "installing kernel + signing tools (few minutes; SMR silences = breathing)"
  arch-chroot /mnt/omarchy pacman -Sy --needed --noconfirm linux mkinitcpio sbsigntools mokutil
  echo "kernel installed"
fi

# --- 6. initramfs: build ONLY if missing ---
if [ -f /mnt/omarchy/boot/initramfs-linux.img ]; then
  echo "initramfs present"
else
  echo "building initramfs"
  arch-chroot /mnt/omarchy mkinitcpio -p linux
fi

# --- 7. user cory (idempotent) ---
arch-chroot /mnt/omarchy /bin/bash -c "id cory >/dev/null 2>&1 || useradd -m -G wheel -s /bin/bash cory; echo 'cory:cove' | chpasswd; sed -i 's/^# %wheel/%wheel/' /etc/sudoers; systemctl enable NetworkManager 2>/dev/null || true"
echo "user cory ready (cory/cove)"

# --- 8. Secure Boot keys (persisted on raft) ---
mkdir -p /mnt/raft/sbkeys /mnt/omarchy/etc/sbkeys
if [ ! -f /mnt/raft/sbkeys/MOK.key ]; then
  openssl req -new -x509 -newkey rsa:2048 -keyout /mnt/raft/sbkeys/MOK.key -out /mnt/raft/sbkeys/MOK.crt -nodes -days 3650 -subj "/CN=Cove Omarchy/" 2>/dev/null
  echo "keys generated (10-year)"
fi
cp /mnt/raft/sbkeys/MOK.key /mnt/raft/sbkeys/MOK.crt /mnt/omarchy/etc/sbkeys/

# --- 9. sign kernel + stage boot files on raft ---
arch-chroot /mnt/omarchy sbsign --key /etc/sbkeys/MOK.key --cert /etc/sbkeys/MOK.crt /boot/vmlinuz-linux --output /boot/vmlinuz-linux.signed
mkdir -p /mnt/raft/omarchy
cp /mnt/omarchy/boot/vmlinuz-linux.signed /mnt/raft/omarchy/
cp /mnt/omarchy/boot/initramfs-linux.img /mnt/raft/omarchy/
echo "kernel signed + boot files staged on raft"

# --- 10. wire vest + ESP ---
cat > /tmp/vest-final.cfg <<CFG
insmod part_gpt
insmod fat
set timeout=10
set default=0
set menu_color_normal=white/black
set menu_color_highlight=black/light-gray
menuentry "Omarchy (Cove)" {
    set root=(hd0,gpt4)
    linux /omarchy/vmlinuz-linux.signed root=UUID=$UUID rw
    initrd /omarchy/initramfs-linux.img
}
menuentry "Ubuntu live (rescue)" {
    set root=(hd0,gpt4)
    set gfxpayload=text
    terminal_output console
    linux /casper/vmlinuz boot=casper iso-scan/filename=/ubuntu-26.04.1-live-server-amd64.iso ---
    initrd /casper/initrd
}
menuentry "Reboot" { reboot }
menuentry "Power off" { halt }
CFG
mkdir -p /mnt/vest
mountpoint -q /mnt/vest || mount /dev/disk/by-label/OMARCHYVEST /mnt/vest
mkdir -p /mnt/vest/boot/grub
cp /tmp/vest-final.cfg /mnt/vest/boot/grub/grub.cfg
mkdir -p /mnt/esp
mountpoint -q /mnt/esp || mount "${DISK}1" /mnt/esp
mkdir -p /mnt/esp/boot/grub
cp /tmp/vest-final.cfg /mnt/esp/boot/grub/grub.cfg
echo "vest + ESP wired (Omarchy first, default)"

# --- 11. re-sign hook (Meri's law) ---
mkdir -p /mnt/omarchy/etc/pacman.d/hooks /mnt/omarchy/usr/local/bin
cat > /mnt/omarchy/etc/pacman.d/hooks/omarchy-resign.hook <<'HK'
[Trigger]
Operation = Install
Operation = Upgrade
Type = Package
Target = linux
[Action]
Description = Re-signing kernel for the Cove vest chain
When = PostTransaction
Exec = /usr/local/bin/omarchy-resign.sh
HK
cat > /mnt/omarchy/usr/local/bin/omarchy-resign.sh <<'RS'
#!/bin/bash
set -e
mkdir -p /mnt/raft-omarchy
mountpoint -q /mnt/raft-omarchy || mount /dev/disk/by-label/OMARCHYRAFT /mnt/raft-omarchy || exit 0
sbsign --key /etc/sbkeys/MOK.key --cert /etc/sbkeys/MOK.crt /boot/vmlinuz-linux --output /boot/vmlinuz-linux.signed
cp /boot/vmlinuz-linux.signed /mnt/raft-omarchy/omarchy/
cp /boot/initramfs-linux.img /mnt/raft-omarchy/omarchy/
umount /mnt/raft-omarchy
RS
chmod +x /mnt/omarchy/usr/local/bin/omarchy-resign.sh
echo "re-sign hook installed"

# --- 12. MOK import (interactive: type omarchy at the prompts) ---
echo "=================================================="
echo "  NEXT: password prompt(s) — TYPE: omarchy"
echo "=================================================="
arch-chroot /mnt/omarchy mokutil --import /etc/sbkeys/MOK.crt

echo "=============================================="
echo "  ALL DONE — $(date)"
echo "  Now: sudo reboot"
echo "  MOK box appears (centered): type omarchy"
echo "  Boot menu: Omarchy (Cove) first, auto-boots in 10s"
echo "  Login: cory / cove"
echo "=============================================="
