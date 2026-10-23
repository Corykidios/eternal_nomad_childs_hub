#!/bin/bash
# omarchy-mission-v2.sh — THE COVE MISSION, complete rewrite (Core, 2026-10-22)
# Self-contained. Run from Ubuntu live console. Everything below is automatic.
set -euo pipefail

echo "=============================================="
echo "  COVE MISSION v2 — start $(date)"
echo "=============================================="

# --- 0. live-env tools (install if missing) ---
NEED=""
for t in tar zstd mkfs.btrfs sbsign mokutil; do command -v $t >/dev/null || NEED="$NEED $t"; done
[ -n "$NEED" ] && { echo "installing tools: $NEED (may take a minute)..."; apt-get update -qq; apt-get install -y -qq btrfs-progs zstd sbsigntool mokutil; }
echo "tools OK"
for t in tar zstd mkfs.btrfs sbsign mokutil; do command -v $t >/dev/null || { echo "FATAL: $t missing"; exit 1; }; done
# --- 0b. find the REAL disk: the one containing partition labels OMARCHYRAFT/OMARCHYVEST ---
# --- find disk via PARTITION->PKNAME (whole-system table, proven on this hull) ---
RAFTNAME=$(lsblk -rno NAME,LABEL | awk '$2=="OMARCHYRAFT"{print $1}' | head -1)
[ -n "$RAFTNAME" ] || { echo "FATAL: OMARCHYRAFT partition not found"; lsblk; exit 1; }
REALDISK=$(lsblk -rno NAME,PKNAME | awk -v r="$RAFTNAME" '$1==r{print $2}' | head -1 | tr -d ' ')
[ -n "$REALDISK" ] || { echo "FATAL: parent disk of $RAFTNAME not found"; lsblk -o NAME,PKNAME; exit 1; }
DISK="/dev/$REALDISK"
echo "disk: $DISK (raft: $RAFTNAME)"

# --- 0c. HEAL: recreate any missing /dev nodes for this disk (kernel sees all; nodes can vanish after mount cascades) ---
NODES=$(lsblk -rno NAME,MAJ:MIN "$DISK" 2>/dev/null | awk '{print $1" "$2}' | tr ':' ' ')
for disknode in $(lsblk -rno NAME,MAJ:MIN "$DISK" 2>/dev/null | awk -F'[: ]' '{print $1":"$2":"$3}'); do
  nm=$(echo "$disknode" | cut -d: -f1); mj=$(echo "$disknode" | cut -d: -f2); mn=$(echo "$disknode" | cut -d: -f3)
  [ -e "/dev/$nm" ] || { mknod "/dev/$nm" b "$mj" "$mn" 2>/dev/null || true; echo "healed node: /dev/$nm"; }
done
[ -e "$DISK" ] || { echo "FATAL: $DISK still missing after heal"; exit 1; }

# --- 1. undo the early bad mount (raft was mounted AT /mnt) ---
mountpoint -q /mnt && { umount /mnt/omarchy 2>/dev/null || true; umount /mnt/raft 2>/dev/null || true; umount /mnt 2>/dev/null || true; }

# --- 2. raft properly at /mnt/raft; clear old explosion debris ---
mkdir -p /mnt/raft
mountpoint -q /mnt/raft || mount /dev/disk/by-label/OMARCHYRAFT /mnt/raft
rm -rf /mnt/raft/ab 2>/dev/null || true
echo "raft contents: $(ls /mnt/raft | tr '\n' ' ')"

# --- 3. target: find existing OMARCHY btrfs, else carve ---
PART="/dev/$(lsblk -rno NAME,LABEL | awk '$2=="OMARCHY"{print $1}' | head -1)"
if [ -z "$PART" ] || [ ! -b "$PART" ]; then
  echo "carving new partition..."
  sfdisk --no-reread --force --append "$DISK" <<< ",+,L"
  partprobe "$DISK"; sleep 3
  PART="/dev/$(lsblk -rno NAME,TYPE | awk '$2=="part"{print $1}' | tail -1)"
  echo "new partition: $PART"
  mkfs.btrfs -f -L OMARCHY "$PART"
fi
blkid "$PART" | grep -q btrfs || mkfs.btrfs -f -L OMARCHY "$PART"
mkdir -p /mnt/omarchy
mountpoint -q /mnt/omarchy || mount "$PART" /mnt/omarchy
UUID=$(blkid -s UUID -o value "$PART")
echo "$UUID" > /mnt/raft/omarchy-uuid.txt
echo "target: $PART  uuid: $UUID"

# --- 4. RAM workshop: extract bootstrap to /tmp (tmpfs: symlinks live free) ---
# --- 4a. clean any previous run's workshop mounts (idempotent rerun) ---
for m in /tmp/ab/root.x86_64/mnt/omarchy /tmp/ab/root.x86_64/dev /tmp/ab/root.x86_64/sys /tmp/ab/root.x86_64/proc; do umount -R "$m" 2>/dev/null || true; done
rm -rf /tmp/ab
mkdir -p /tmp/ab
tar --use-compress-program=unzstd -xf /mnt/raft/archlinux-bootstrap-x86_64.tar.zst -C /tmp/ab
R=/tmp/ab/root.x86_64
mount --bind /proc $R/proc; mount --make-rslave $R/proc
mount --rbind /sys  $R/sys; mount --make-rslave $R/sys
mount --rbind /dev  $R/dev; mount --make-rslave $R/dev
cp /etc/resolv.conf $R/etc/resolv.conf
mkdir -p $R/mnt/omarchy
mount --bind /mnt/omarchy $R/mnt/omarchy
echo "workshop ready in RAM"

# --- 4b. ARCH MIRROR FIX: bootstrap ships ALL mirrors commented out ---
sed -i "s/^#Server/Server/" $R/etc/pacman.d/mirrorlist
MIRRORS=$(grep -c "^Server" $R/etc/pacman.d/mirrorlist || true)
[ "$MIRRORS" -gt 0 ] || { echo "FATAL: no mirrors available"; exit 1; }
echo "mirrors enabled: $MIRRORS"

# --- 5. pacstrap Arch into the target (the long stretch — SMR disk, silence = breathing) ---
chroot $R /bin/bash -c "pacman -Sy --noconfirm archlinux-keyring && pacstrap -K /mnt/omarchy base linux linux-firmware btrfs-progs sudo networkmanager curl sbsigntool vim mokutil"
echo "pacstrap done"

# --- 6. fstab (manual, exact) ---
echo "UUID=$UUID / btrfs defaults,noatime 0 1" > /mnt/omarchy/etc/fstab

# --- 7. configure the new system ---
mount --rbind /proc /mnt/omarchy/proc 2>/dev/null || true; mount --make-rslave /mnt/omarchy/proc 2>/dev/null || true
mount --rbind /sys  /mnt/omarchy/sys  2>/dev/null || true; mount --make-rslave /mnt/omarchy/sys 2>/dev/null || true
mount --rbind /dev  /mnt/omarchy/dev  2>/dev/null || true; mount --make-rslave /mnt/omarchy/dev 2>/dev/null || true
chroot /mnt/omarchy /bin/bash -c "
ln -sf /usr/share/zoneinfo/America/New_York /etc/localtime
sed -i 's/^#en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
locale-gen
echo 'LANG=en_US.UTF-8' > /etc/locale.conf
echo cove > /etc/hostname
systemctl enable NetworkManager
useradd -m -G wheel -s /bin/bash cory 2>/dev/null || true
echo 'cory:cove' | chpasswd
sed -i 's/^# %wheel/%wheel/' /etc/sudoers
sed -i 's/^MODULES=(/MODULES=(btrfs /' /etc/mkinitcpio.conf
mkinitcpio -P
"
echo "configuration done"

# --- 8. Secure Boot keys (persisted on raft + inside the system for the hook) ---
mkdir -p /mnt/raft/sbkeys /mnt/omarchy/etc/sbkeys
if [ ! -f /mnt/raft/sbkeys/MOK.key ]; then
  openssl req -new -x509 -newkey rsa:2048 -keyout /mnt/raft/sbkeys/MOK.key -out /mnt/raft/sbkeys/MOK.crt -nodes -days 3650 -subj "/CN=Cove Omarchy/"
fi
cp /mnt/raft/sbkeys/MOK.key /mnt/raft/sbkeys/MOK.crt /mnt/omarchy/etc/sbkeys/
sbsign --key /mnt/raft/sbkeys/MOK.key --cert /mnt/raft/sbkeys/MOK.crt /mnt/omarchy/boot/vmlinuz-linux --output /mnt/omarchy/boot/vmlinuz-linux.signed
mv /mnt/omarchy/boot/vmlinuz-linux.signed /mnt/omarchy/boot/vmlinuz-linux
echo "kernel signed"

# --- 9. boot files onto the raft + vest config v4 ---
mkdir -p /mnt/raft/omarchy
cp /mnt/omarchy/boot/vmlinuz-linux      /mnt/raft/omarchy/vmlinuz-linux.signed
cp /mnt/omarchy/boot/initramfs-linux.img /mnt/raft/omarchy/initramfs-linux.img
mkdir -p /mnt/vest
mountpoint -q /mnt/vest || mount /dev/disk/by-label/OMARCHYVEST /mnt/vest
cat > /tmp/vest-grub.cfg <<CFG
insmod part_gpt
insmod fat
set timeout=10
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
cp /tmp/vest-grub.cfg /mnt/vest/boot/grub/grub.cfg
mkdir -p /mnt/esp
mountpoint -q /mnt/esp || mount "${DISK}1" /mnt/esp
cp /tmp/vest-grub.cfg /mnt/esp/boot/grub/grub.cfg
echo "vest + ESP wired"

# --- 10. re-sign hook (Meri's law: every future kernel update re-signs + refreshes the raft) ---
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
mv /boot/vmlinuz-linux.signed /boot/vmlinuz-linux
cp /boot/vmlinuz-linux /mnt/raft-omarchy/omarchy/vmlinuz-linux.signed
cp /boot/initramfs-linux.img /mnt/raft-omarchy/omarchy/initramfs-linux.img
umount /mnt/raft-omarchy
RS
chmod +x /mnt/omarchy/usr/local/bin/omarchy-resign.sh
echo "re-sign hook installed"

# --- 11. request MOK enrollment (LAST STEP — two password prompts, type: omarchy) ---
echo "=================================================="
echo "  NEXT: password prompt(s). TYPE: omarchy"
echo "=================================================="
mokutil --import /mnt/raft/sbkeys/MOK.crt

echo "=============================================="
echo "  ALL DONE — $(date)"
echo "  Now: sudo reboot"
echo "  MOK box appears (centered): type omarchy"
echo "  Then boot menu -> Omarchy (Cove) auto-boots in 10s"
echo "  Login: cory / cove"
echo "=============================================="
