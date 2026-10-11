"""Non-destructive tests: real temp-directory transfers, mocked host services."""
import os
from pathlib import Path
import platform
import shlex
import shutil
import subprocess
import tempfile
import unittest
import zipfile


SCRIPT = Path(__file__).resolve().parents[3] / "usb-autorun-installer.sh"


class AutorunTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / "usb"
        self.dest = self.root / "public"
        self.source.mkdir()
        self.dest.mkdir()
        (self.source / "new video.mp4").write_bytes(b"new video data")
        (self.source / ".hidden").write_text("also copied")
        # Old timestamps expose checksum dry-run differences hidden when both
        # fixture creation and copy happen in the same second.
        for item in self.source.iterdir():
            os.utime(item, (1_600_000_000, 1_600_000_000))
        (self.dest / "old.mp4").write_text("keep until verified")
        self.bin_dir = self.root / "bin"
        self.bin_dir.mkdir()
        if platform.system() != "Linux":
            # macOS openrsync lacks --fsync. Keep real file-copy/checksum behavior,
            # but leave Linux durability validation to the Fedora integration test.
            real_rsync = shlex.quote(shutil.which("rsync"))
            wrapper = self.bin_dir / "rsync"
            wrapper.write_text(f'''#!/bin/bash
args=()
for arg in "$@"; do [[ $arg == --fsync ]] || args+=("$arg"); done
exec {real_rsync} "${{args[@]}}"
''')
            wrapper.chmod(0o755)

    def run_shell(self, body):
        setup = f"""
set -euo pipefail
source {shlex.quote(str(SCRIPT))}
DEST={shlex.quote(str(self.dest))}
MP={shlex.quote(str(self.source))}
USER_GROUP=$(id -gn)
export PATH={shlex.quote(str(self.bin_dir))}:"$PATH"
# Only root-only metadata and Linux service operations are substituted.
chown() {{ :; }}
restorecon() {{ :; }}
user_systemctl() {{ printf 'SYSTEMCTL %s\\n' "$*" >&2; }}
notify_user() {{ printf 'NOTIFY %s | %s\\n' "$1" "$2" >&2; }}
STATE_DIR={shlex.quote(str(self.root / "state"))}
PENDING_FILE="$STATE_DIR/pending-set"
RUN_DIR={shlex.quote(str(self.root / "run"))}
FOLDER_FILE="$RUN_DIR/kodi-folder"
"""
        if platform.system() != "Linux":
            # GNU sync -f is Linux-specific; test its error handling below.
            setup += 'sync() { :; }\n'
        return subprocess.run(["bash", "-c", setup + body], text=True,
                              capture_output=True)

    def test_success_copies_hidden_files_replaces_old_and_keeps_the_drive(self):
        result = self.run_shell('import_contents "$MP"')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.dest / "new video.mp4").read_bytes(), b"new video data")
        self.assertEqual((self.dest / ".hidden").read_text(), "also copied")
        self.assertFalse((self.dest / "old.mp4").exists())
        self.assertTrue((self.source / "new video.mp4").exists(), "drives are never modified")

    def test_copy_failure_preserves_usb_and_previous_destination(self):
        result = self.run_shell('rsync() { return 23; }; import_contents "$MP"')
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((self.source / "new video.mp4").exists())
        self.assertTrue((self.dest / "old.mp4").exists())
        self.assertIn("copy", result.stderr.lower())

    def test_checksum_mismatch_preserves_usb_and_previous_destination(self):
        result = self.run_shell('''
rsync() {
    case " $* " in
        *" --dry-run "*) printf '%s\\n' '>fcsT...... new video.mp4' ;;
        *) command rsync "$@" ;;
    esac
}
import_contents "$MP"
''')
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((self.source / "new video.mp4").exists())
        self.assertTrue((self.dest / "old.mp4").exists())
        self.assertIn("verification", result.stderr.lower())

    def test_empty_usb_preserves_previous_destination(self):
        for item in self.source.iterdir():
            item.unlink()
        result = self.run_shell('import_contents "$MP"')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.dest / "old.mp4").exists())

    def test_symlinks_on_the_drive_are_not_followed(self):
        secret = self.root / "secret"
        secret.mkdir()
        (secret / "key").write_text("private")
        (self.source / "outside").symlink_to(secret, target_is_directory=True)
        result = self.run_shell('import_contents "$MP"')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.dest / "outside" / "key").exists())

    def test_relabel_failure_keeps_usb_copy(self):
        result = self.run_shell('restorecon() { return 1; }; import_contents "$MP"')
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((self.source / "new video.mp4").exists())
        self.assertIn("SELinux relabel failed", result.stderr)
        backups = list(self.root.glob(".usb-autorun-old.*/content/old.mp4"))
        self.assertEqual(len(backups), 1)
        self.assertEqual(backups[0].read_text(), "keep until verified")

    def test_copy_failure_cleans_partial_staging_directory(self):
        result = self.run_shell('''
rsync() { command rsync "$@"; return 23; }
import_contents "$MP"
''')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("copy failed", result.stderr)
        self.assertEqual(list(self.root.glob(".usb-autorun-new.*")), [])

    def test_staging_flush_failure_preserves_source_and_previous_destination(self):
        result = self.run_shell('''
# Bare sync cannot report the simulated writeback error; sync -f can.
sync() { if [[ ${1:-} == -f ]]; then return 1; fi; }
import_contents "$MP"
''')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("flush", result.stderr.lower())
        self.assertTrue((self.source / "new video.mp4").exists())
        self.assertTrue((self.dest / "old.mp4").exists())

    def test_published_copy_flush_failure_keeps_usb_and_backup(self):
        result = self.run_shell('''
sync() { if [[ ${1:-} == -f && ${2:-} == "$DEST" ]]; then return 1; fi; }
import_contents "$MP"
''')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("flush", result.stderr.lower())
        self.assertTrue((self.source / "new video.mp4").exists())
        self.assertEqual(len(list(self.root.glob(".usb-autorun-old.*/content/old.mp4"))), 1)

    def session_fixture(self, *, active="yes", locked="no", remote="no", display=True):
        return f'''
USER_NAME=desktop
loginctl() {{
    if [[ $1 == list-sessions ]]; then printf '2 1000 desktop seat0 1234 user - no -\\n'; return; fi
    case "$4" in
        Name) echo desktop ;; Remote) echo {remote} ;; Type) echo wayland ;;
        Active) echo {active} ;; LockedHint) echo {locked} ;;
        *) return 1 ;;
    esac
}}
user_systemctl() {{
    case "$1" in
        is-active) return 0 ;;
        show-environment) printf '%s\\n' {'WAYLAND_DISPLAY=wayland-0' if display else 'HOME=/home/desktop'} ;;
        *) return 1 ;;
    esac
}}
require_graphical_session
'''

    def test_active_wayland_session_uses_user_manager_environment(self):
        result = self.run_shell(self.session_fixture())
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_locked_inactive_remote_or_unready_session_is_rejected(self):
        for options, message in [
            ({"locked": "yes"}, "Unlock"),
            ({"active": "no"}, "Log into"),
            ({"remote": "yes"}, "Exactly one"),
            ({"display": False}, "display"),
        ]:
            with self.subTest(options=options):
                result = self.run_shell(self.session_fixture(**options))
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(message, result.stderr)

    def test_media_is_claimed_only_while_user_holds_the_seat(self):
        for seat, owner, expected in [("4", "desktop", 0), ("4", "other", 1), ("", "desktop", 1)]:
            with self.subTest(seat=seat, owner=owner):
                result = self.run_shell(f'''
USER_NAME=desktop
loginctl() {{
    case "$1" in
        show-seat) echo {shlex.quote(seat)} ;;
        show-session) echo {owner} ;;
    esac
}}
owns_seat || exit 1
''')
                self.assertEqual(result.returncode, expected, result.stderr)

    def test_unsafe_destination_rejected(self):
        for dest in ["/", "/home", "/home/../etc", "/srv", "/etc", "/home/a/b"]:
            with self.subTest(dest=dest):
                result = self.run_shell(f'DEST={shlex.quote(dest)}; validate_destination')
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("destination", result.stderr.lower())

    def test_folder_is_handed_to_the_kodi_player(self):
        result = self.run_shell('show_in_kodi "$DEST"')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.root / "run" / "kodi-folder").read_text(), f"{self.dest}\n")
        self.assertIn("SYSTEMCTL restart usb-autorun-player.service", result.stderr)

    def run_player(self, *, running):
        (self.root / "run").mkdir()
        (self.root / "run" / "kodi-folder").write_text(f"{self.dest}\n")
        return self.run_shell(f'''
validate_user() {{ USER_ID=$EUID; }}
WAYLAND_DISPLAY=wayland-0 FULLSCREEN=yes
checks=0
kodi_running() {{ checks=$((checks + 1)); {"(( checks < 3 ))" if running else "false"}; }}
systemd-run() {{ echo "STARTED $*"; }}
systemctl() {{ return 0; }}
kodi_rpc() {{ echo "RPC $1"; }}
sleep() {{ :; }}
open_kodi
''')

    def test_player_starts_kodi_and_opens_the_folder(self):
        result = self.run_player(running=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--unit=app-usb-autorun-kodi.service -p TimeoutStopSec=10 -- kodi -fs",
                      result.stdout)
        self.assertIn(f'"method":"GUI.ActivateWindow","params":{{"window":"videos",'
                      f'"parameters":["{self.dest}/","return"]}}', result.stdout)

    def test_player_reuses_a_running_kodi_until_it_closes(self):
        result = self.run_player(running=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("STARTED", result.stdout)
        self.assertIn("GUI.ActivateWindow", result.stdout)

    def test_vlc_is_never_started(self):
        code = [line for line in SCRIPT.read_text().splitlines()
                if not line.lstrip().startswith("#") and "VLC is never started" not in line]
        self.assertNotIn("vlc", "\n".join(code).lower())

    # Zip sets: a stored (uncompressed) movie spread over several volumes.
    def make_zip(self):
        self.movie = os.urandom(300_000)
        whole = self.root / "whole.zip"
        with zipfile.ZipFile(whole, "w", zipfile.ZIP_STORED) as archive:
            archive.writestr("movie.mkv", self.movie)
            archive.writestr("notes.txt", "hello")
        return whole.read_bytes()

    def make_split_parts(self, directory, size=100_000):
        """7-Zip/split style: set.zip.001, set.zip.002, ..."""
        data = self.make_zip()
        directory.mkdir(parents=True, exist_ok=True)
        names = []
        for number, start in enumerate(range(0, len(data), size), 1):
            name = f"set.zip.{number:03d}"
            (directory / name).write_bytes(data[start:start + size])
            names.append(name)
        return names

    def zip_status(self, directory, zip_set="set.zip"):
        return self.run_shell(f'zip_set_status {shlex.quote(str(directory))} {zip_set}')

    def test_split_set_reports_first_missing_part_then_complete(self):
        parts = self.root / "parts"
        names = self.make_split_parts(parts)
        self.assertEqual(len(names), 4)
        (parts / names[-1]).rename(self.root / names[-1])
        self.assertEqual(self.zip_status(parts).stdout, "missing set.zip.004\n")
        (self.root / names[-1]).rename(parts / names[-1])
        (parts / names[1]).unlink()
        self.assertEqual(self.zip_status(parts).stdout, "missing set.zip.002\n")
        self.make_split_parts(parts)
        self.assertEqual(self.zip_status(parts).stdout, f"complete {parts}/set.zip.001\n")

    def test_end_record_split_across_the_last_two_parts_is_found(self):
        parts = self.root / "parts"
        data = self.make_zip()
        parts.mkdir()
        (parts / "set.zip.001").write_bytes(data[:-10])
        (parts / "set.zip.002").write_bytes(data[-10:])
        self.assertEqual(self.zip_status(parts).stdout, f"complete {parts}/set.zip.001\n")

    @unittest.skipUnless(shutil.which("zip"), "Info-ZIP zip is required")
    def test_span_set_needs_final_zip_and_every_volume(self):
        source = self.root / "span-source"
        source.mkdir()
        (source / "movie.mkv").write_bytes(os.urandom(300_000))
        parts = self.root / "parts"
        parts.mkdir()
        subprocess.run(["zip", "-q", "-0", "-s", "100k", str(parts / "set.zip"), "movie.mkv"],
                       cwd=source, check=True)
        self.assertEqual(sorted(p.name for p in parts.iterdir()),
                         ["set.z01", "set.z02", "set.zip"])
        self.assertEqual(self.zip_status(parts).stdout, f"complete {parts}/set.zip\n")
        (parts / "set.zip").rename(self.root / "set.zip")
        self.assertEqual(self.zip_status(parts).stdout, "missing set.z03 or set.zip\n")
        (self.root / "set.zip").rename(parts / "set.zip")
        (parts / "set.z02").unlink()
        self.assertEqual(self.zip_status(parts).stdout, "missing set.z02\n")

    def test_part_names(self):
        result = self.run_shell('''
for name in a.zip.001 "my movie.zip.012" b.z01 c.zip c.mp4 d.zip.1; do
    part_set "$name" || echo "no: $name"
done
''')
        self.assertEqual(result.stdout.splitlines(),
                         ["a.zip", "my movie.zip", "b.zip", "no: c.zip", "no: c.mp4", "no: d.zip.1"])

    def insert_disc(self, label, disc):
        return self.run_shell(f'''
copy_disc_parts {shlex.quote(str(disc))} {label}
if [[ -n $disc_set ]]; then finish_disc_parts "$disc_set" {label}; else echo NO_PARTS; fi
''')

    @unittest.skipUnless(shutil.which("7z"), "7-Zip is required")
    def test_discs_collect_parts_then_extract_and_open_in_kodi(self):
        staging = self.root / "all-parts"
        names = self.make_split_parts(staging)
        disc1, disc2 = self.root / "disc1", self.root / "disc2"
        (disc1 / "sub").mkdir(parents=True)
        disc2.mkdir()
        shutil.copy(staging / names[0], disc1 / "sub")
        shutil.copy(staging / names[1], disc1)
        for name in names[1:]:  # Repeats part 2, which must not be copied twice.
            shutil.copy(staging / name, disc2)

        first = self.insert_disc(1, disc1)
        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertEqual(sorted(p.name for p in self.dest.iterdir()), names[:2])
        self.assertEqual((self.root / "state" / "pending-set").read_text(), "set.zip\n")
        self.assertIn("NOTIFY Insert disc 2 | Disc 1 is copied. Still needed: set.zip.003.",
                      first.stderr)
        self.assertTrue((disc1 / "sub" / names[0]).exists(), "discs are never modified")

        second = self.insert_disc(2, disc2)
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual(sorted(p.name for p in self.dest.iterdir()), ["movie.mkv", "notes.txt"])
        self.assertEqual((self.dest / "movie.mkv").read_bytes(), self.movie)
        self.assertFalse((self.root / "state" / "pending-set").exists())
        self.assertEqual((self.root / "run" / "kodi-folder").read_text(), f"{self.dest}\n")
        self.assertIn("SYSTEMCTL restart usb-autorun-player.service", second.stderr)
        self.assertEqual(list(self.root.glob(".usb-autorun-*")), [])

    def test_disc_from_another_set_is_refused_while_one_is_pending(self):
        (self.root / "state").mkdir()
        (self.root / "state" / "pending-set").write_text("set.zip\n")
        disc = self.root / "disc"
        disc.mkdir()
        (disc / "other.zip.001").write_text("part")
        result = self.insert_disc(1, disc)
        self.assertEqual(result.returncode, 3, result.stderr)
        self.assertIn("NOTIFY Disc 1 not imported | It belongs to other.zip, but set.zip", result.stderr)
        self.assertEqual([p.name for p in self.dest.iterdir()], ["old.mp4"])

    def test_disc_without_parts_leaves_destination_alone(self):
        disc = self.root / "disc"
        disc.mkdir()
        (disc / "film.mkv").write_text("v")
        (disc / "unrelated.zip").write_text("not a part")
        result = self.insert_disc(1, disc)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("NO_PARTS", result.stdout)
        self.assertEqual([p.name for p in self.dest.iterdir()], ["old.mp4"])

    def test_rom_files_named_like_span_parts_are_not_parts(self):
        disc = self.root / "disc"
        (disc / "N64").mkdir(parents=True)
        (disc / "film.mkv").write_text("v")
        for rom in ["Castlevania.z64", "Mario.z64"]:
            (disc / "N64" / rom).write_bytes(b"\x80\x37\x12\x40 rom")
        # The same ROM zipped beside its extracted copy, in two folders.
        with zipfile.ZipFile(disc / "N64" / "Mario.zip", "w") as archive:
            archive.writestr("Mario.z64", b"\x80\x37\x12\x40 rom")
        (disc / "N64" / "Mario").mkdir()
        (disc / "N64" / "Mario" / "Mario.z64").write_bytes(b"\x80\x37\x12\x40 rom")
        result = self.insert_disc(1, disc)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("NO_PARTS", result.stdout)
        self.assertEqual([p.name for p in self.dest.iterdir()], ["old.mp4"])

    @unittest.skipUnless(shutil.which("zip"), "Info-ZIP zip is required")
    def test_span_parts_are_proven_by_signature_final_zip_or_pending_set(self):
        source = self.root / "span-source"
        source.mkdir()
        (source / "movie.mkv").write_bytes(os.urandom(300_000))
        staging = self.root / "span"
        staging.mkdir()
        subprocess.run(["zip", "-q", "-0", "-s", "100k", str(staging / "set.zip"), "movie.mkv"],
                       cwd=source, check=True)
        for label, names, expected in [
            ("first", ["set.z01"], ["set.z01"]),  # Signature, beside a video.
            ("last", ["set.zip", "set.z02"], ["set.z02", "set.zip"]),  # Final zip.
            ("alone", ["set.z02"], ["set.z02"]),  # Nothing else on the disc.
        ]:
            with self.subTest(disc=label):
                disc = self.root / f"disc-{label}"
                disc.mkdir()
                for name in names:
                    shutil.copy(staging / name, disc)
                if label == "first":
                    (disc / "film.mkv").write_text("v")
                shutil.rmtree(self.root / "state", ignore_errors=True)
                result = self.insert_disc(1, disc)
                self.assertNotIn("NO_PARTS", result.stdout, result.stderr)
                self.assertEqual(sorted(p.name for p in self.dest.iterdir()), expected)

    def write_watch(self, text):
        (self.source / "Movies" / "Saga").mkdir(parents=True)
        (self.source / "Movies" / "Saga" / "part 1.mkv").write_text("p1")
        (self.source / "Movies" / "Saga" / "part 2.mkv").write_text("p2")
        (self.source / "Movies" / "skip.mkv").write_text("not listed")
        (self.source / "watch.txt").write_bytes(text.encode())

    def test_watch_txt_copies_listed_paths_keeping_folders(self):
        self.write_watch("# tonight\r\n/new video.mp4\r\n\r\n  Movies/Saga  \r\n")
        result = self.run_shell('''
list=$(mktemp)
watch_list "$MP" "$list"
import_contents "$MP" "$list" tree
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        copied = sorted(str(p.relative_to(self.dest)) for p in self.dest.rglob("*") if p.is_file())
        self.assertEqual(copied, ["Movies/Saga/part 1.mkv", "Movies/Saga/part 2.mkv", "new video.mp4"])

    def test_watch_txt_entries_must_exist_on_the_drive(self):
        (self.root / "secret").write_text("private")
        (self.source / "link").symlink_to(self.root / "secret")
        for entry, message in [("missing.mkv", "Not found on the drive: missing.mkv"),
                               ("../secret", "Not on the drive: ../secret"),
                               ("link", "Not on the drive: link"),
                               ("# only a comment", "It lists no files.")]:
            with self.subTest(entry=entry):
                shutil.rmtree(self.source / "Movies", ignore_errors=True)
                self.write_watch(entry + "\n")
                result = self.run_shell('watch_list "$MP" "$(mktemp)"')
                self.assertEqual(result.returncode, 3, result.stderr)
                self.assertIn(f"NOTIFY watch.txt not used | {message}", result.stderr)

    def handle_media(self, properties, *, pending=False):
        if pending:
            (self.root / "state").mkdir()
            (self.root / "state" / "pending-set").write_text("set.zip\n")
        # The mock mount bind-copies the fixture drive into the mount point.
        return self.run_shell(f'''
USER_NAME=$(id -un) USER_ID=$(id -u) FS_LABEL=TEMP name=sdx1 dev=/dev/sdx1 mp='' kind='' disc_set=''
properties={shlex.quote(properties)}
require_graphical_session() {{ :; }}
findmnt() {{ return 1; }}
mount() {{ cp -R "$MP"/. "${{@: -1}}"; echo MOUNTED; }}
mountpoint() {{ return 1; }}
flock() {{ :; }}
wait_for_kodi_close() {{ echo KODI_CLOSED; }}
lsblk() {{ echo sdx; }}
udisksctl() {{ echo "POWER_OFF $*"; }}
eject() {{ echo "EJECT $*"; }}
handle_media
''')

    def test_other_drive_opens_in_kodi_and_powers_off_when_kodi_closes(self):
        result = self.handle_media("ID_BUS=usb\nID_FS_LABEL=Movies\nID_FS_TYPE=exfat")
        self.assertEqual(result.returncode, 0, result.stderr)
        folder = (self.root / "run" / "kodi-folder").read_text().strip()
        self.assertTrue(folder.startswith(str(self.root / "run" / "media.")), folder)
        self.assertEqual([p.name for p in self.dest.iterdir()], ["old.mp4"])
        self.assertEqual(result.stdout.split("\n")[1:3],
                         ["KODI_CLOSED", "POWER_OFF power-off --no-user-interaction -b /dev/sdx"])

    def test_usb_hard_drive_reporting_the_ata_bus_is_handled(self):
        result = self.handle_media(
            "ID_BUS=ata\nID_USB_DRIVER=usb-storage\nID_FS_LABEL=Toshiba\nID_FS_TYPE=ext4")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("KODI_CLOSED\nPOWER_OFF", result.stdout)

    def test_internal_drive_is_refused(self):
        result = self.handle_media("ID_BUS=ata\nID_FS_LABEL=Data\nID_FS_TYPE=ext4")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("non-USB", result.stderr)
        self.assertNotIn("MOUNTED", result.stdout)

    def test_temp_drive_is_copied_then_released_when_kodi_closes(self):
        result = self.handle_media("ID_BUS=usb\nID_FS_LABEL=temp\nID_FS_TYPE=vfat")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(sorted(p.name for p in self.dest.iterdir()), [".hidden", "new video.mp4"])
        self.assertEqual((self.root / "run" / "kodi-folder").read_text(), f"{self.dest}\n")
        self.assertIn("KODI_CLOSED\nPOWER_OFF", result.stdout)

    def test_disc_is_browsed_and_ejected_when_kodi_closes(self):
        result = self.handle_media("ID_CDROM_MEDIA=1\nID_FS_LABEL=FILMS\nID_FS_TYPE=udf")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("KODI_CLOSED\nEJECT /dev/sdx1", result.stdout)

    def test_copies_are_refused_while_a_zip_set_is_pending(self):
        result = self.handle_media("ID_BUS=usb\nID_FS_LABEL=TEMP\nID_FS_TYPE=vfat", pending=True)
        self.assertEqual(result.returncode, 3, result.stderr)
        self.assertIn("NOTIFY Drive not copied", result.stderr)
        self.assertEqual([p.name for p in self.dest.iterdir()], ["old.mp4"])

    def test_release_waits_for_kodi_to_start_then_close(self):
        result = self.run_shell('''
calls=0
kodi_running() { calls=$((calls + 1)); (( calls >= 3 && calls < 5 )); }
sleep() { :; }
wait_for_kodi_close
echo "checks=$calls"
''')
        self.assertEqual(result.stdout.strip(), "checks=5", result.stderr)

    def test_help_works_without_root(self):
        result = subprocess.run(["bash", str(SCRIPT), "--help"],
                                text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--user", result.stdout)


if __name__ == "__main__":
    unittest.main()
