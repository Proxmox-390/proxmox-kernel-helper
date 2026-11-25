#!/bin/sh
# Tests for the zipl backend (proxmox-boot/zipl-functions, the zy-proxmox-zipl kernel hook and the
# kernel commands of proxmox-boot-tool). They run anywhere, without root and without booting: all
# files live below a scratch root ($PBT_ROOT), and uname, dpkg, apt-config and zipl are the
# stand-ins in test/fake. The stand-in zipl checks the configuration it is given (images exist,
# unique sections, usable default) and records which configuration a real run "wrote".
set -e
here="$(cd "$(dirname "$0")" && pwd)"
src="$(dirname "$here")"
work="$(mktemp -d "${TMPDIR:-/tmp}/pbt-zipl-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT

# the scripts under test, with their fixed paths pointing at the source tree
mkdir -p "$work/bin" "$work/hooks"
for f in bin/proxmox-boot-tool proxmox-boot/zy-proxmox-zipl proxmox-boot/proxmox-auto-removal; do
	sed -e "s#/usr/share/proxmox-kernel-helper/scripts#$src/proxmox-boot#g" "$src/$f" > "$work/bin/$(basename "$f")"
	chmod +x "$work/bin/$(basename "$f")"
done
cp "$work/bin/zy-proxmox-zipl" "$work/hooks/"
PATH="$here/fake:$PATH"
PBT_HOOK_DIR="$work/hooks"
export PATH PBT_HOOK_DIR

D612="6.12.118+deb13-s390x"
P1="7.3.6-1+s390x1-pve"
P2="7.3.6-1+s390x2-pve"
P3="7.3.7-1+s390x1-pve"

fails=0
tests=0
current=""

begin() {
	current="$1"
	tests=$((tests + 1))
	PBT_ROOT="$work/root-$tests"
	export PBT_ROOT
	mkdir -p "$PBT_ROOT/etc/kernel" "$PBT_ROOT/boot" "$PBT_ROOT/sys/firmware/reipl"
	: > "$PBT_ROOT/packages"
	: > "$PBT_ROOT/zipl.calls"
	echo unknown > "$PBT_ROOT/sys/firmware/reipl/reipl_type"
	FAKE_RUNNING="$D612"
	export FAKE_RUNNING
	unset FAKE_ZIPL_REJECT
	cp "$here/fixtures/${2:-installer.conf}" "$PBT_ROOT/etc/zipl.conf"
	cp "$PBT_ROOT/etc/zipl.conf" "$PBT_ROOT/zipl.conf.orig"
	# a Debian kernel with the links the installer's configuration boots
	add_image "$D612"
	ln -s "vmlinuz-$D612" "$PBT_ROOT/boot/vmlinuz"
	ln -s "initrd.img-$D612" "$PBT_ROOT/boot/initrd.img"
}

fail() {
	fails=$((fails + 1))
	echo "FAIL [$current]: $*"
}

add_image() {
	: > "$PBT_ROOT/boot/vmlinuz-$1"
	[ -n "$2" ] || : > "$PBT_ROOT/boot/initrd.img-$1"
}

# a Proxmox kernel package with its files, then its postinst hook
install_kernel() {
	add_image "$1" "$2"
	echo "proxmox-kernel-$1" >> "$PBT_ROOT/packages"
	hook "$1"
}

remove_kernel() {
	rm -f "$PBT_ROOT/boot/vmlinuz-$1" "$PBT_ROOT/boot/initrd.img-$1"
	grep -v -x -F "proxmox-kernel-$1" "$PBT_ROOT/packages" > "$PBT_ROOT/packages.new" || true
	mv "$PBT_ROOT/packages.new" "$PBT_ROOT/packages"
	hook "$1"
}

hook() {
	hook_rc=0
	"$work/hooks/zy-proxmox-zipl" "$1" "/boot/vmlinuz-$1" > "$PBT_ROOT/hook.out" 2>&1 || hook_rc=$?
}

pbt() {
	pbt_rc=0
	"$work/bin/proxmox-boot-tool" "$@" > "$PBT_ROOT/pbt.out" 2>&1 < /dev/null || pbt_rc=$?
}

conf() { cat "$PBT_ROOT/etc/zipl.conf"; }
default() { sed -n 's/^[[:space:]]*default[[:space:]]*=[[:space:]]*//p' "$PBT_ROOT/etc/zipl.conf" | head -n1; }
managed() { sed -n 's/^\[proxmox-\(.*\)\]$/\1/p' "$PBT_ROOT/etc/zipl.conf" | tr '\n' ' ' | sed 's/ $//'; }
# everything the administrator wrote: the file without the managed block and the default line
user_part() {
	sed -e '/^# BEGIN proxmox-boot-tool/,/^# END proxmox-boot-tool/d' -e '/^[[:space:]]*default[[:space:]]*=/d' "$1" |
		sed -e :a -e '/^\n*$/{$d;N;ba' -e '}'
}

expect() { # <what> <expected> <actual>
	[ "$2" = "$3" ] || fail "$1: expected '$2', got '$3'"
}
expect_rc() { expect "exit status" "$1" "$2"; }
expect_untouched() {
	cmp -s "$PBT_ROOT/etc/zipl.conf" "$PBT_ROOT/zipl.conf.orig" || fail "zipl.conf was changed"
}
expect_user_part_kept() {
	user_part "$PBT_ROOT/etc/zipl.conf" > "$PBT_ROOT/u.now"
	user_part "$PBT_ROOT/zipl.conf.orig" > "$PBT_ROOT/u.orig"
	cmp -s "$PBT_ROOT/u.now" "$PBT_ROOT/u.orig" || fail "sections outside the managed block changed"
}
expect_bootable() {
	# the configuration in place is accepted by zipl and is the one last written to "disk"
	zipl --dry-run > /dev/null 2>&1 || fail "zipl does not accept the configuration in place"
	[ ! -e "$PBT_ROOT/bootrecord" ] || cmp -s "$PBT_ROOT/bootrecord" "$PBT_ROOT/etc/zipl.conf" ||
		fail "the boot record was not written for the configuration in place"
}
expect_no_leftovers() {
	left="$(ls "$PBT_ROOT/etc" | grep -E 'pbt-(new|user|log)' || true)"
	[ -z "$left" ] || fail "temporary files left: $left"
}
real_runs() { grep -c -v -- '--dry-run' "$PBT_ROOT/zipl.calls" || true; }

# ---------------------------------------------------------------------------------------------

begin "Debian kernel only: nothing is touched"
hook "$D612"
expect_rc 0 "$hook_rc"
expect_untouched
expect "zipl runs" 0 "$(real_runs)"
expect_no_leftovers

begin "first Proxmox kernel becomes the default, running Debian kernel is the fallback"
install_kernel "$P1"
expect_rc 0 "$hook_rc"
expect "default" "proxmox-$P1" "$(default)"
expect "managed entries" "$P1 $D612" "$(managed)"
expect_user_part_kept
expect_bootable
expect_no_leftovers
cmp -s "$PBT_ROOT/etc/zipl.conf.pbt-bak" "$PBT_ROOT/zipl.conf.orig" || fail "backup is not the previous configuration"
grep -q '^# BEGIN proxmox-boot-tool managed boot entries (original default: debian)$' "$PBT_ROOT/etc/zipl.conf" ||
	fail "block header does not record the original default"
n="$(grep -c '^parameters="root=/dev/mapper/pve-root console=ttysclp0"$' "$PBT_ROOT/etc/zipl.conf")"
expect "sections with the administrator's parameters" 4 "$n"
grep -q "^ramdisk=/boot/initrd.img-$P1\$" "$PBT_ROOT/etc/zipl.conf" || fail "no ramdisk line"
expect "menu entry of the old default" "Adding #1: IPL section 'debian'" "$(zipl --dry-run | grep "'debian'")"

begin "a second run changes nothing and does not run zipl"
install_kernel "$P1"
cp "$PBT_ROOT/etc/zipl.conf" "$PBT_ROOT/first"
before="$(real_runs)"
hook "$P1"
cmp -s "$PBT_ROOT/etc/zipl.conf" "$PBT_ROOT/first" || fail "not idempotent"
expect "additional zipl runs" "$before" "$(real_runs)"

begin "a newer Proxmox kernel takes over, the running one stays second"
install_kernel "$P1"
FAKE_RUNNING="$P1"
install_kernel "$P2"
expect "default" "proxmox-$P2" "$(default)"
expect "managed entries" "$P2 $P1" "$(managed)"
install_kernel "$P3"
expect "default" "proxmox-$P3" "$(default)"
expect "managed entries" "$P3 $P1 $P2" "$(managed)"
expect_user_part_kept
expect_bootable

begin "pin and unpin"
install_kernel "$P1"
install_kernel "$P2"
pbt kernel pin "$P1"
expect_rc 0 "$pbt_rc"
expect "default after pin" "proxmox-$P1" "$(default)"
expect_bootable
install_kernel "$P3"
expect "default after a newer kernel arrived" "proxmox-$P1" "$(default)"
pbt kernel unpin
expect_rc 0 "$pbt_rc"
expect "default after unpin" "proxmox-$P3" "$(default)"
expect_bootable

begin "pinning the Debian kernel keeps a new Proxmox kernel from becoming the default"
pbt kernel pin "$D612"
expect_rc 0 "$pbt_rc"
expect "default with only the pinned Debian kernel" "proxmox-$D612" "$(default)"
install_kernel "$P1"
expect "default" "proxmox-$D612" "$(default)"
expect "managed entries" "$D612 $P1" "$(managed)"
expect_bootable

begin "pin of a kernel that is not installed is refused"
install_kernel "$P1"
cp "$PBT_ROOT/etc/zipl.conf" "$PBT_ROOT/first"
pbt kernel pin "9.9.9-1-pve"
expect_rc 1 "$pbt_rc"
cmp -s "$PBT_ROOT/etc/zipl.conf" "$PBT_ROOT/first" || fail "configuration changed"
[ ! -e "$PBT_ROOT/etc/kernel/proxmox-boot-pin" ] || fail "pin file written"

begin "removing a kernel removes its entry"
install_kernel "$P1"
install_kernel "$P2"
remove_kernel "$P2"
expect_rc 0 "$hook_rc"
expect "default" "proxmox-$P1" "$(default)"
expect "managed entries" "$P1 $D612" "$(managed)"
expect_bootable

begin "removing the default kernel while it is pinned falls back to the newest"
install_kernel "$P1"
install_kernel "$P2"
pbt kernel pin "$P1"
remove_kernel "$P1"
expect_rc 0 "$hook_rc"
expect "default" "proxmox-$P2" "$(default)"
expect_bootable

begin "removing the last Proxmox kernel restores the original configuration"
install_kernel "$P1"
remove_kernel "$P1"
expect_rc 0 "$hook_rc"
expect "default" "debian" "$(default)"
expect "managed entries" "" "$(managed)"
cmp -s "$PBT_ROOT/etc/zipl.conf" "$PBT_ROOT/zipl.conf.orig" || fail "not back to the original file"
expect_bootable

begin "removing a Debian kernel that had an entry" hand-added.conf
install_kernel "$P1"
FAKE_RUNNING="$P1"
rm -f "$PBT_ROOT/boot/vmlinuz-$D612" "$PBT_ROOT/boot/initrd.img-$D612"
# the administrator's [debian] section now misses its image: zipl rejects the whole file
hook "$D612"
expect_rc 0 "$hook_rc"
grep -q "boots as before" "$PBT_ROOT/hook.out" || fail "no warning about the rejected configuration"

begin "zipl rejects the new configuration: nothing is changed"
FAKE_ZIPL_REJECT=1; export FAKE_ZIPL_REJECT
install_kernel "$P1"
expect_rc 0 "$hook_rc"
expect_untouched
expect "zipl runs" 0 "$(real_runs)"
expect_no_leftovers
grep -q "boots as before" "$PBT_ROOT/hook.out" || fail "no warning"
pbt refresh
expect_untouched

begin "zipl fails after the configuration was replaced: previous one restored"
echo 1 > "$PBT_ROOT/zipl.fail"
install_kernel "$P1"
expect_rc 0 "$hook_rc"
expect_untouched
expect_bootable
expect "zipl runs (failed, then for the restored file)" 2 "$(real_runs)"
grep -q "previous configuration restored" "$PBT_ROOT/hook.out" || fail "no message about the restore"

begin "zipl fails for the restored configuration as well: the hook fails"
echo 2 > "$PBT_ROOT/zipl.fail"
install_kernel "$P1"
expect_rc 1 "$hook_rc"
expect_untouched
grep -q "MAY NOT BOOT" "$PBT_ROOT/hook.out" || fail "no loud warning"

begin "hand-written spacing, comments and extra settings are kept" spaced.conf
install_kernel "$P1"
expect_rc 0 "$hook_rc"
expect "default" "proxmox-$P1" "$(default)"
grep -q "^	default = proxmox-$P1\$" "$PBT_ROOT/etc/zipl.conf" || fail "spelling of the default line changed"
expect_user_part_kept
n="$(grep -c 'parameters = "root=UUID=0a1b2c3d-1111-2222-3333-444455556666 rd.dasd=0.0.0200 console=ttysclp0 console=tty3270 quiet"$' "$PBT_ROOT/etc/zipl.conf")"
expect "sections with the parameters" 3 "$n"
expect "sections with 'secure = auto'" 3 "$(grep -c 'secure = auto' "$PBT_ROOT/etc/zipl.conf")"
grep -q "original default: linux" "$PBT_ROOT/etc/zipl.conf" || fail "original default not recorded"
expect_bootable
remove_kernel "$P1"
grep -q "^	default = linux\$" "$PBT_ROOT/etc/zipl.conf" || fail "original default not restored"

begin "a section the administrator added for the same kernel stays" hand-added.conf
install_kernel "$P1"
expect_rc 0 "$hook_rc"
grep -q '^\[pve73\]$' "$PBT_ROOT/etc/zipl.conf" || fail "hand-added section removed"
expect "default" "proxmox-$P1" "$(default)"
expect_user_part_kept
expect_bootable
expect "menu number of the hand-added entry" "Adding #3: IPL section 'pve73'" "$(zipl --dry-run | grep "'pve73'")"

begin "a hand-written section for a Proxmox kernel is the default: upgrade, clean-up, removal" hand-default.conf
# a system that got a Proxmox kernel before the helper knew zipl: image installed, section and
# default written by hand, running that kernel
add_image "$P2"
echo "proxmox-kernel-$P2" >> "$PBT_ROOT/packages"
FAKE_RUNNING="$P2"
install_kernel "$P3"
expect_rc 0 "$hook_rc"
expect "default" "proxmox-$P3" "$(default)"
expect "managed entries" "$P3 $P2" "$(managed)"
grep -q '^\[pve73\]$' "$PBT_ROOT/etc/zipl.conf" || fail "hand-written section removed"
grep -q "original default: pve73" "$PBT_ROOT/etc/zipl.conf" || fail "original default not recorded"
expect "sections with the hand-written parameters" 3 "$(grep -c 'kvm.nested=1"$' "$PBT_ROOT/etc/zipl.conf")"
expect_user_part_kept
expect_bootable
# the administrator removes the hand-written section: the first remaining section takes its place
# as the source of the settings and as the default to go back to
sed -i '/^\[pve73\]$/,$d' "$PBT_ROOT/etc/zipl.conf"
pbt refresh
expect_rc 0 "$pbt_rc"
expect "default" "proxmox-$P3" "$(default)"
expect "managed entries" "$P3 $P2" "$(managed)"
grep -q "original default: debian" "$PBT_ROOT/etc/zipl.conf" || fail "original default not moved to [debian]"
expect "sections with the hand-written parameters" 0 "$(grep -c 'kvm.nested=1"$' "$PBT_ROOT/etc/zipl.conf")"
expect_bootable
FAKE_RUNNING="$P3"
remove_kernel "$P2"
expect_rc 0 "$hook_rc"
expect "managed entries" "$P3" "$(managed)"
expect_bootable

begin "a hand-written section whose kernel is removed blocks the update, with a warning" hand-default.conf
add_image "$P2"
echo "proxmox-kernel-$P2" >> "$PBT_ROOT/packages"
install_kernel "$P3"
FAKE_RUNNING="$P3"
cp "$PBT_ROOT/etc/zipl.conf" "$PBT_ROOT/first"
remove_kernel "$P2"
expect_rc 0 "$hook_rc"
cmp -s "$PBT_ROOT/etc/zipl.conf" "$PBT_ROOT/first" || fail "configuration changed although zipl rejects it"
grep -q "boots as before" "$PBT_ROOT/hook.out" || fail "no warning"

begin "[defaultboot] without a default line gets one" no-default.conf
install_kernel "$P1"
expect_rc 0 "$hook_rc"
expect "default" "proxmox-$P1" "$(default)"
expect_bootable

begin "a hand-written menu is left alone" defaultmenu.conf
ln -s "vmlinuz-$D612" "$PBT_ROOT/boot/vmlinuz.old"
install_kernel "$P1"
expect_rc 0 "$hook_rc"
expect_untouched
grep -q "not managing" "$PBT_ROOT/hook.out" || fail "no explanation"

begin "boot loader specification entries: left alone"
mkdir -p "$PBT_ROOT/boot/loader/entries"
: > "$PBT_ROOT/boot/loader/entries/x.conf"
install_kernel "$P1"
expect_rc 0 "$hook_rc"
expect_untouched

begin "kernel without an initramfs gets no ramdisk line"
install_kernel "$P1" no-initrd
expect_rc 0 "$hook_rc"
if grep -q "^ramdisk=/boot/initrd.img-$P1\$" "$PBT_ROOT/etc/zipl.conf"; then fail "ramdisk line for a missing file"; fi
expect_bootable

begin "the parameters are taken from the reference section again on refresh"
install_kernel "$P1"
sed -i 's/console=ttysclp0"$/console=ttysclp0 kvm.nested=1"/' "$PBT_ROOT/etc/zipl.conf"
# only the [debian] and [old] sections count, the edit inside the block is overwritten
pbt refresh
expect_rc 0 "$pbt_rc"
expect "sections with the new parameter" 4 "$(grep -c 'kvm.nested=1"$' "$PBT_ROOT/etc/zipl.conf")"
sed -i '/^\[debian\]$/,/^$/s/ kvm.nested=1"$/"/' "$PBT_ROOT/etc/zipl.conf"
pbt refresh
expect "sections with the parameter after removing it from [debian]" 1 "$(grep -c 'kvm.nested=1"$' "$PBT_ROOT/etc/zipl.conf")"
expect_bootable

begin "refresh always writes the boot record"
install_kernel "$P1"
before="$(real_runs)"
pbt refresh
expect_rc 0 "$pbt_rc"
expect "zipl runs" "$((before + 1))" "$(real_runs)"

begin "next boot through the re-IPL selector (CCW): default untouched"
mkdir -p "$PBT_ROOT/sys/firmware/reipl/ccw"
echo ccw > "$PBT_ROOT/sys/firmware/reipl/reipl_type"
echo "" > "$PBT_ROOT/sys/firmware/reipl/ccw/loadparm"
install_kernel "$P1"
FAKE_RUNNING="$P1"
install_kernel "$P2"
pbt kernel pin "$P1" --next-boot
expect_rc 0 "$pbt_rc"
expect "default" "proxmox-$P2" "$(default)"
want="$(zipl --dry-run | sed -n "s/^Adding #\([0-9]*\): IPL section 'proxmox-$P1'.*/\1/p")"
expect "loadparm" "$want" "$(cat "$PBT_ROOT/sys/firmware/reipl/ccw/loadparm")"
[ -n "$want" ] || fail "no menu number"
pbt kernel unpin --next-boot
expect_rc 0 "$pbt_rc"
expect "loadparm after unpin" "" "$(cat "$PBT_ROOT/sys/firmware/reipl/ccw/loadparm")"
expect "default after unpin" "proxmox-$P2" "$(default)"
[ ! -e "$PBT_ROOT/etc/kernel/next-boot-pin" ] || fail "next-boot pin left"
[ ! -e "$PBT_ROOT/etc/kernel/next-boot-pin.reipl" ] || fail "flag file left"

begin "next boot through the re-IPL selector (FCP)"
mkdir -p "$PBT_ROOT/sys/firmware/reipl/fcp"
echo fcp > "$PBT_ROOT/sys/firmware/reipl/reipl_type"
echo 0 > "$PBT_ROOT/sys/firmware/reipl/fcp/bootprog"
install_kernel "$P1"
install_kernel "$P2"
pbt kernel pin "$P1" --next-boot
expect_rc 0 "$pbt_rc"
expect "default" "proxmox-$P2" "$(default)"
want="$(zipl --dry-run | sed -n "s/^Adding #\([0-9]*\): IPL section 'proxmox-$P1'.*/\1/p")"
expect "bootprog" "$want" "$(cat "$PBT_ROOT/sys/firmware/reipl/fcp/bootprog")"
pbt kernel unpin --next-boot
expect "bootprog after unpin" "0" "$(cat "$PBT_ROOT/sys/firmware/reipl/fcp/bootprog")"

begin "next boot without a re-IPL selector: temporary default"
install_kernel "$P1"
install_kernel "$P2"
pbt kernel pin "$P1" --next-boot
expect_rc 0 "$pbt_rc"
expect "default while pinned for the next boot" "proxmox-$P1" "$(default)"
grep -q "becomes the default" "$PBT_ROOT/pbt.out" || fail "no explanation"
expect_bootable
pbt kernel unpin --next-boot
expect "default after unpin" "proxmox-$P2" "$(default)"
expect_bootable

begin "kernel list shows the boot entries"
install_kernel "$P1"
pbt kernel list
expect_rc 0 "$pbt_rc"
grep -q "^proxmox-$P1 \* (managed)\$" "$PBT_ROOT/pbt.out" || fail "default entry not marked"
grep -q "^debian (manual)\$" "$PBT_ROOT/pbt.out" || fail "manual entry not listed"

begin "packages of other kernels do not confuse the list"
echo "proxmox-kernel-7.3" >> "$PBT_ROOT/packages"
echo "linux-image-$D612" >> "$PBT_ROOT/packages"
install_kernel "$P1"
expect "managed entries" "$P1 $D612" "$(managed)"

echo "$tests tests, $fails failure(s)"
[ "$fails" -eq 0 ]
