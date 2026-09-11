#!/bin/sh
# Prepare the Xalies HAOS AIO installer v0.8.0 for a legacy-BIOS install
# without editing HAOS's update-managed EFI/BOOT/grub.cfg.
set -eu

INSTALLER_DIR=/usr/local/bin/haos-installer
LEGACY_FILE="$INSTALLER_DIR/legacy-bios.sh"
RUNNER=/usr/local/bin/haos-installer-run
EXPECTED_LEGACY_SHA256=997b09dda02751cf7fab9cc9037f03bb586283547665a2156c62156c658a3343

fail() {
  printf '\nERROR: %s\n' "$*" >&2
  printf 'Nothing has been written to the laptop disk by this preparation script.\n' >&2
  exit 1
}

[ "$(id -u)" -eq 0 ] || fail "Run this from the installer shell as root."
[ -f "$LEGACY_FILE" ] || fail "This is not the expected HAOS AIO installer environment."
[ -x "$RUNNER" ] || fail "The HAOS installer runner is missing."
command -v sha256sum >/dev/null 2>&1 || fail "sha256sum is missing."

ACTUAL_LEGACY_SHA256="$(sha256sum "$LEGACY_FILE" | awk '{print $1}')"
[ "$ACTUAL_LEGACY_SHA256" = "$EXPECTED_LEGACY_SHA256" ] ||
  fail "The live installer does not match the reviewed v0.8.0 legacy script (found $ACTUAL_LEGACY_SHA256)."

cp "$LEGACY_FILE" "$LEGACY_FILE.xalies-original"

cat > "$LEGACY_FILE" <<'LEGACY_EOF'
#!/bin/sh
set -eu

bios_boot_partition_label="HAOS BIOS Boot"

configure_legacy_bios_boot() {
  target_disk="$1"

  installer_legacy_bios_enabled || return 0

  log_warn "Update-resilient legacy BIOS boot support is enabled for $target_disk."

  if [ "${HAOS_DRY_RUN:-0}" != "0" ]; then
    log_info "DRY RUN: add a BIOS Boot partition and install the persistent GRUB bridge on $target_disk"
    return 0
  fi

  for command_name in grub-editenv grub-install jq mount sgdisk sync umount; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
      log_error "Legacy BIOS support requires missing command: $command_name"
      return 1
    fi
  done

  run_step "Adding update-resilient legacy BIOS boot support." install_legacy_grub "$target_disk"
}

install_legacy_grub() {
  target_disk="$1"

  sgdisk -e "$target_disk"
  sgdisk -n "0:-4M:0" -t "0:EF02" -c "0:$bios_boot_partition_label" "$target_disk"
  reread_partition_table "$target_disk"
  udevadm settle >/dev/null 2>&1 || true

  bios_boot_partition="$(wait_for_partition_by_label "$target_disk" "$bios_boot_partition_label")"
  if [ -z "$bios_boot_partition" ]; then
    log_error "Could not find the BIOS Boot partition after creating it."
    return 1
  fi

  efi_partition="$(find_efi_partition "$target_disk")"
  if [ -z "$efi_partition" ]; then
    log_error "Could not find the HAOS EFI partition for the legacy GRUB bridge."
    return 1
  fi

  efi_mount="$(mktemp -d)"
  trap 'umount "$efi_mount" >/dev/null 2>&1 || true; rmdir "$efi_mount" >/dev/null 2>&1 || true' EXIT

  mount "$efi_partition" "$efi_mount"
  haos_grub_cfg="$(find_haos_efi_grub_cfg "$efi_mount")"
  if [ ! -f "$haos_grub_cfg" ]; then
    log_error "The official HAOS GRUB configuration is missing: $haos_grub_cfg"
    return 1
  fi

  # The bridge depends on the current HAOS config using its default grubenv.
  # We deliberately do not patch this update-managed file.
  if ! grep -Eq '^[[:space:]]*load_env[[:space:]]*$' "$haos_grub_cfg"; then
    log_error "The official HAOS GRUB configuration has an unexpected load_env line."
    return 1
  fi
  if ! grep -Eq '^[[:space:]]*save_env[[:space:]]+' "$haos_grub_cfg"; then
    log_error "The official HAOS GRUB configuration has no expected save_env line."
    return 1
  fi

  legacy_boot_dir="$efi_mount/HAOS-LEGACY"
  legacy_grub_dir="$legacy_boot_dir/grub"
  mkdir -p "$legacy_grub_dir"

  # Install BIOS GRUB into a separately named directory. HAOS's updater merges
  # a new boot image onto this FAT partition and does not delete this directory.
  grub-install \
    --target=i386-pc \
    --boot-directory="$legacy_boot_dir" \
    --recheck \
    "$target_disk"

  if [ ! -d "$legacy_grub_dir/i386-pc" ]; then
    log_error "grub-install did not create the expected i386-pc module directory."
    return 1
  fi

  # The official GRUB config expects its unqualified load_env/save_env commands
  # to resolve relative to EFI/BOOT. Copy BIOS modules there so commands can
  # still auto-load after the bridge changes GRUB's prefix to that directory.
  haos_grub_dir="$(dirname "$haos_grub_cfg")"
  mkdir -p "$haos_grub_dir/i386-pc"
  cp -R "$legacy_grub_dir/i386-pc/." "$haos_grub_dir/i386-pc/"

  haos_cmdline=""
  if [ -f "$efi_mount/cmdline.txt" ]; then
    haos_cmdline="$(tr -d '\r\n' < "$efi_mount/cmdline.txt")"
  fi
  grub_cmdline="$(printf '%s' "$haos_cmdline" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\$/\\$/g')"

  cat > "$legacy_grub_dir/grub.cfg" <<GRUBCFG
# Persistent BIOS-to-HAOS bridge installed by haos-legacy-update-safe-installer.sh.
# HAOS owns EFI/BOOT/grub.cfg and may replace it during an OS update.
search --no-floppy --set=root --file /EFI/BOOT/grub.cfg
set haos_cmdline="$grub_cmdline"

# HAOS's patched UEFI GRUB provides file_env. Standard BIOS GRUB does not, so
# supply the one value used by the current HAOS config from the installed file.
function file_env {
    set cmdline="\$haos_cmdline"
}

# This makes HAOS's own unqualified load_env/save_env use its official grubenv.
# The copied i386-pc modules keep dynamic command and filesystem loading working.
set prefix=(\$root)/EFI/BOOT
configfile (\$root)/EFI/BOOT/grub.cfg
GRUBCFG

  reset_haos_grubenv_attempts "$haos_grub_cfg"

  # Verify the known update-sensitive file stayed untouched.
  if grep -Eq '^[[:space:]]*load_env[[:space:]]+--file' "$haos_grub_cfg"; then
    log_error "Refusing to finish because the official HAOS grub.cfg was modified."
    return 1
  fi

  sync
  umount "$efi_mount"
  rmdir "$efi_mount"
  trap - EXIT

  log_info "Update-resilient legacy BIOS GRUB bridge installed on $target_disk."
  log_info "The official HAOS EFI/BOOT/grub.cfg was left unmodified."
}

reset_haos_grubenv_attempts() {
  grub_cfg="$1"
  grubenv_path="$(dirname "$grub_cfg")/grubenv"

  if [ ! -f "$grubenv_path" ]; then
    log_warn "HAOS GRUB environment not found at $grubenv_path; legacy boot may enter rescue after failed attempts."
    return 0
  fi

  grub-editenv "$grubenv_path" set A_TRY=0 B_TRY=0 A_OK=1 ORDER="A B"
}

find_haos_efi_grub_cfg() {
  efi_mount="$1"

  for grub_cfg in \
    "$efi_mount/EFI/BOOT/grub.cfg" \
    "$efi_mount/efi/boot/grub.cfg" \
    "$efi_mount/EFI/boot/grub.cfg" \
    "$efi_mount/efi/BOOT/grub.cfg"; do
    if [ -f "$grub_cfg" ]; then
      printf '%s\n' "$grub_cfg"
      return 0
    fi
  done

  printf '%s\n' "$efi_mount/EFI/BOOT/grub.cfg"
}

find_partition_by_label() {
  target_disk="$1"
  label="$2"

  partition_path="$(lsblk -J -o PATH,PARTLABEL "$target_disk" \
    | jq -r --arg label "$label" '.blockdevices[0].children[]? | select(.partlabel == $label) | .path' \
    | head -n 1)"
  if [ -n "$partition_path" ]; then
    printf '%s\n' "$partition_path"
    return 0
  fi

  partition_number="$(sgdisk -p "$target_disk" 2>/dev/null | awk -v label="$label" 'index($0, label) { print $1; exit }')"
  [ -n "$partition_number" ] || return 1

  case "$target_disk" in
    *[0-9]) partition_path="${target_disk}p${partition_number}" ;;
    *) partition_path="${target_disk}${partition_number}" ;;
  esac

  [ -b "$partition_path" ] || return 1
  printf '%s\n' "$partition_path"
}

wait_for_partition_by_label() {
  target_disk="$1"
  label="$2"

  for _ in 1 2 3 4 5 6 7 8 9 10; do
    partition_path="$(find_partition_by_label "$target_disk" "$label" 2>/dev/null || true)"
    if [ -n "$partition_path" ]; then
      printf '%s\n' "$partition_path"
      return 0
    fi

    reread_partition_table "$target_disk"
    udevadm settle >/dev/null 2>&1 || true
    sleep 1
  done

  return 1
}
LEGACY_EOF

chmod 0755 "$LEGACY_FILE"

printf '\nPrepared the live installer for an update-resilient legacy-BIOS install.\n'
printf 'The USB has not been changed, and the laptop disk has not been written yet.\n'
printf 'Starting the normal attended HAOS installer now.\n\n'

export HAOS_LEGACY_BIOS=1
exec "$RUNNER"
