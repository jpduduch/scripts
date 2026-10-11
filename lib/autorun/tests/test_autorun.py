"""Non-destructive tests: real temp-directory transfers, mocked host services."""
import os
from pathlib import Path
import platform
import shlex
import shutil
import subprocess
import unittest
import tempfile
import zipfile


SCRIPT = Path(__file__).resolve().parents[3] / "usb-autorun-installer.sh"
# Media scanning uses GNU find's -regextype; the tool targets Fedora anyway.
linux_only = unittest.skipUnless(platform.system() == "Linux", "GNU find is required")

IGNORED = 4
REFUSED = 3


class AutorunTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / "media"          # stands in for a mount point
        self.dest = self.root / "Videos"
        self.source.mkdir()
        self.dest.mkdir()
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

    # Old timestamps expose checksum dry-run differences that would be hidden
    # when fixture creation and the copy happen in the same second.
    def age(self, *paths):
        for path in paths:
            os.utime(path, (1_600_000_000, 1_600_000_000))

    def video(self, relative, data=b"video data"):
        path = self.source / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        self.age(path)
        return path

    def run_shell(self, body):
        setup = f"""
set -euo pipefail
source {shlex.quote(str(SCRIPT))}
HOME={shlex.quote(str(self.root))}
DEST={shlex.quote(str(self.dest))}
TEMP_DIR="$DEST/temp"
STATE_DIR={shlex.quote(str(self.root / "state"))}
HANDLED_FILE="$STATE_DIR/handled"
MP={shlex.quote(str(self.source))}
export PATH={shlex.quote(str(self.bin_dir))}:"$PATH"
# The only substitution: the desktop notification bus.
notify_user() {{ printf 'NOTIFY %s | %s\\n' "$1" "$2" >&2; }}
"""
        return subprocess.run(["bash", "-c", setup + body], text=True, capture_output=True)

    def names_in(self, directory):
        return sorted(p.name for p in Path(directory).iterdir())

    # ------------------------------------------------------------- copy_item

    def test_copy_item_copies_a_file_and_leaves_the_media_alone(self):
        self.video("Movies/film.mkv", b"film data")
        result = self.run_shell('copied=0; copy_item "$MP/Movies/film.mkv" film.mkv "$DEST"')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.dest / "film.mkv").read_bytes(), b"film data")
        self.assertTrue((self.source / "Movies" / "film.mkv").exists(), "media is never modified")

    def test_copy_item_leaves_an_existing_name_untouched(self):
        self.video("film.mkv", b"new")
        (self.dest / "film.mkv").write_bytes(b"keep me")
        result = self.run_shell('copied=0; copy_item "$MP/film.mkv" film.mkv "$DEST"; echo "copied=$copied"')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.dest / "film.mkv").read_bytes(), b"keep me")
        self.assertIn("copied=0", result.stdout)

    def test_copy_item_copies_a_folder_whole(self):
        self.video("Saga/part 1.mkv", b"p1")
        self.video("Saga/extras/clip.mp4", b"clip")
        self.age(self.source / "Saga", self.source / "Saga" / "extras")
        result = self.run_shell('copied=0; copy_item "$MP/Saga" Saga "$DEST"')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.dest / "Saga" / "part 1.mkv").read_bytes(), b"p1")
        self.assertEqual((self.dest / "Saga" / "extras" / "clip.mp4").read_bytes(), b"clip")

    def test_copy_failure_removes_the_partial_copy_and_keeps_the_media(self):
        self.video("film.mkv")
        result = self.run_shell(
            'copied=0; rsync() { return 23; }; copy_item "$MP/film.mkv" film.mkv "$DEST"')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.dest / "film.mkv").exists())
        self.assertTrue((self.source / "film.mkv").exists())
        self.assertIn("Copying film.mkv failed", result.stderr)

    def test_checksum_mismatch_removes_the_copy_and_keeps_the_media(self):
        self.video("film.mkv")
        result = self.run_shell('''
copied=0
rsync() {
    case " $* " in
        *" --dry-run "*) printf '%s\\n' '>fcsT...... film.mkv' ;;
        *) command rsync "$@" ;;
    esac
}
copy_item "$MP/film.mkv" film.mkv "$DEST"
''')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.dest / "film.mkv").exists())
        self.assertTrue((self.source / "film.mkv").exists())
        self.assertIn("Verification found differences", result.stderr)

    def test_symlinks_on_the_media_are_not_followed(self):
        secret = self.root / "secret"
        secret.mkdir()
        (secret / "key").write_text("private")
        self.video("Saga/part 1.mkv", b"p1")
        (self.source / "Saga" / "outside").symlink_to(secret, target_is_directory=True)
        self.age(self.source / "Saga")
        result = self.run_shell('copied=0; copy_item "$MP/Saga" Saga "$DEST"')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.dest / "Saga" / "outside" / "key").exists())

    # ------------------------------------------------------------ destination

    def test_destination_must_be_a_folder_inside_the_users_home(self):
        for dest, reason in [("$HOME", "itself"),
                             ("/srv/videos", "must live inside"),
                             ("/run/media/joao/TEMP", "removable")]:
            with self.subTest(dest=dest):
                result = self.run_shell(f'DEST="{dest}"; validate_destination')
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(reason, result.stderr)

    def test_destination_is_created_when_missing(self):
        shutil.rmtree(self.dest)
        result = self.run_shell("validate_destination")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.dest.is_dir())

    # -------------------------------------------------------------- selection

    def select(self, extra=""):
        return self.run_shell(extra + '''
sel_src=() sel_name=() cand_parts=() cand_zips=() parts=()
whole_media_selection "$MP"
classify_parts
for n in ${sel_name[@]+"${sel_name[@]}"}; do printf 'NAME %s\\n' "$n"; done
for n in ${parts[@]+"${parts[@]}"}; do printf 'PART %s\\n' "$n"; done
''')

    def tagged(self, result, tag):
        return sorted(line[len(tag) + 1:] for line in result.stdout.splitlines()
                      if line.startswith(tag + " "))

    @linux_only
    def test_whole_media_picks_up_every_video_whatever_the_case_or_depth(self):
        self.video("Top.MKV")
        self.video("a/b/deep movie.mp4")
        self.video("a/notes.txt")
        self.video("a/cover.JPG")
        result = self.select()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.tagged(result, "NAME"), ["Top.MKV", "deep movie.mp4"])

    @linux_only
    def test_split_volumes_are_parts_and_plain_zips_are_ignored(self):
        self.make_split_parts(self.source / "sub")
        self.video("unrelated.zip", b"not a part")
        result = self.select()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([Path(p).name for p in self.tagged(result, "PART")],
                         [f"set.zip.{n:03d}" for n in range(1, 5)])
        self.assertEqual(self.tagged(result, "NAME"), [])

    @linux_only
    def test_rom_files_named_like_span_parts_are_not_parts(self):
        self.video("film.mkv")
        for rom in ["Castlevania.z64", "Mario.z64"]:
            self.video(f"N64/{rom}", b"\x80\x37\x12\x40 rom")
        # The same ROM zipped beside its extracted copy, in two folders.
        with zipfile.ZipFile(self.source / "N64" / "Mario.zip", "w") as archive:
            archive.writestr("Mario.z64", b"\x80\x37\x12\x40 rom")
        self.video("N64/Mario/Mario.z64", b"\x80\x37\x12\x40 rom")
        result = self.select()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.tagged(result, "PART"), [])
        self.assertEqual(self.tagged(result, "NAME"), ["film.mkv"])

    @linux_only
    @unittest.skipUnless(shutil.which("zip"), "Info-ZIP zip is required")
    def test_span_parts_are_proven_by_signature_final_zip_or_collected_set(self):
        staging = self.make_span_parts()
        for label, names, collected, expected in [
            ("signature", ["set.z01"], [], ["set.z01"]),
            ("final zip", ["set.z02", "set.zip"], [], ["set.z02", "set.zip"]),
            ("unproven", ["set.z02"], [], []),
            ("collecting", ["set.z02"], ["set.z01"], ["set.z02"]),
        ]:
            with self.subTest(disc=label):
                shutil.rmtree(self.source, ignore_errors=True)
                shutil.rmtree(self.dest / "temp", ignore_errors=True)
                self.source.mkdir()
                for name in names:
                    shutil.copy(staging / name, self.source)
                if collected:
                    (self.dest / "temp").mkdir(parents=True, exist_ok=True)
                    for name in collected:
                        shutil.copy(staging / name, self.dest / "temp")
                self.video("film.mkv")
                result = self.select()
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual([Path(p).name for p in self.tagged(result, "PART")], expected)

    @linux_only
    @unittest.skipUnless(shutil.which("zip"), "Info-ZIP zip is required")
    def test_a_rom_is_not_swallowed_by_a_real_span_of_the_same_name(self):
        # set.z01/set.z02/set.zip is a genuine 3-volume span; set.z64 beside it
        # is a Nintendo 64 ROM, and volume 64 cannot exist in a 3-volume span.
        staging = self.make_span_parts()
        for part in staging.iterdir():
            shutil.copy(part, self.source)
            self.age(self.source / part.name)
        self.video("set.z64", b"\x80\x37\x12\x40 rom")
        result = self.select()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([Path(p).name for p in self.tagged(result, "PART")],
                         ["set.z01", "set.z02", "set.zip"])
        self.assertIn("which spans 3 volumes: set.z64", result.stderr)

    @linux_only
    def test_a_lone_z64_needs_a_z63_even_when_its_set_is_collecting(self):
        # Without the final .zip the span's length is unknown, so the only
        # guarantee left is that volumes run upwards from .z01 with no gaps.
        (self.dest / "temp").mkdir(parents=True)
        (self.dest / "temp" / "zelda.z01").write_bytes(os.urandom(500))
        self.video("Zelda.z64", b"\x80\x37\x12\x40 rom")
        result = self.select()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.tagged(result, "PART"), [])
        self.assertIn("no zelda.z63 to go with it", result.stderr)

    @linux_only
    def test_a_z64_is_taken_once_the_whole_chain_below_it_is_there(self):
        (self.dest / "temp").mkdir(parents=True)
        for n in range(1, 63):
            (self.dest / "temp" / f"big.z{n:02d}").write_bytes(os.urandom(64))
        for name in ["big.z63", "big.z64"]:
            self.video(name, os.urandom(64))
        result = self.select()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([Path(p).name for p in self.tagged(result, "PART")],
                         ["big.z63", "big.z64"])

    @linux_only
    def test_a_gap_below_a_volume_rejects_it_and_everything_above_it(self):
        (self.dest / "temp").mkdir(parents=True)
        (self.dest / "temp" / "big.z01").write_bytes(os.urandom(64))
        for name in ["big.z63", "big.z64"]:   # z02..z62 are missing
            self.video(name, os.urandom(64))
        result = self.select()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.tagged(result, "PART"), [],
                         "z64 must not ride in on a z63 that was itself refused")

    @linux_only
    def test_an_absurd_volume_number_does_not_hang_the_scan(self):
        (self.dest / "temp").mkdir(parents=True)
        (self.dest / "temp" / "thing.z01").write_bytes(os.urandom(64))
        self.video("thing.z99999999", b"rom")
        result = self.select()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.tagged(result, "PART"), [])

    # --------------------------------------------------------------- watch.txt

    def write_watch(self, text):
        self.video("Movies/Saga/part 1.mkv", b"p1")
        self.video("Movies/Saga/part 2.mkv", b"p2")
        self.video("Movies/skip.mkv", b"not listed")
        self.video("Docs/readme.txt", b"no video here")
        self.video("new video.mp4", b"new video data")
        (self.source / "watch.txt").write_bytes(text.encode())

    def watch(self):
        return self.run_shell('''
sel_src=() sel_name=() cand_parts=() cand_zips=()
watch_selection "$MP"
for n in ${sel_name[@]+"${sel_name[@]}"}; do printf 'NAME %s\\n' "$n"; done
for n in ${cand_parts[@]+"${cand_parts[@]}"}; do printf 'PART %s\\n' "$n"; done
''')

    @linux_only
    def test_watch_txt_takes_listed_files_and_folders_that_hold_a_video(self):
        self.write_watch("# tonight\r\n/new video.mp4\r\n\r\n  Movies/Saga  \r\nDocs\r\n")
        result = self.watch()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.tagged(result, "NAME"), ["Saga", "new video.mp4"])
        self.assertIn("No video inside, skipped: Docs", result.stderr)

    @linux_only
    def test_watch_txt_folder_is_copied_whole_into_the_destination(self):
        self.write_watch("Movies/Saga\n")
        self.age(self.source / "Movies" / "Saga")
        result = self.run_shell('import_mount "$MP" "" no')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.names_in(self.dest), ["Saga"])
        self.assertEqual(self.names_in(self.dest / "Saga"), ["part 1.mkv", "part 2.mkv"])

    def test_watch_txt_entries_must_exist_on_the_drive(self):
        for listing, message in [
            ("Movies/missing.mkv\n", "Not found on the drive"),
            ("../outside\n", "Not found on the drive"),
            ("# only comments\n", "It names nothing to copy"),
        ]:
            with self.subTest(listing=listing):
                self.write_watch(listing)
                result = self.watch()
                self.assertEqual(result.returncode, REFUSED, result.stderr)
                self.assertIn(message, result.stderr)

    def test_watch_txt_cannot_reach_outside_the_drive_through_a_symlink(self):
        self.write_watch("escape\n")
        (self.source / "escape").symlink_to(self.root, target_is_directory=True)
        result = self.watch()
        self.assertEqual(result.returncode, REFUSED, result.stderr)
        self.assertIn("Not on the drive: escape", result.stderr)

    @linux_only
    def test_watch_txt_zip_parts_are_collected_not_copied_flat(self):
        self.make_split_parts(self.source)
        self.write_watch("set.zip.001\nset.zip.002\n")
        result = self.watch()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.tagged(result, "NAME"), [])
        self.assertEqual([Path(p).name for p in self.tagged(result, "PART")],
                         ["set.zip.001", "set.zip.002"])

    @linux_only
    @unittest.skipUnless(shutil.which("zip"), "Info-ZIP zip is required")
    def test_a_watched_zip_that_is_a_spans_last_volume_goes_to_temp(self):
        staging = self.make_span_parts()
        for name in ["set.z01", "set.zip"]:
            shutil.copy(staging / name, self.source)
            self.age(self.source / name)
        (self.source / "watch.txt").write_text("set.z01\nset.zip\n")
        result = self.run_shell('import_mount "$MP" "" no')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.names_in(self.dest), ["temp"], "the .zip is not left loose")
        self.assertEqual(self.names_in(self.dest / "temp"), ["set.z01", "set.zip"])

    # ------------------------------------------------------------ import_mount

    @linux_only
    def test_unlabelled_drive_without_watch_txt_is_left_to_gnome(self):
        self.video("film.mkv")
        result = self.run_shell('import_mount "$MP" "MY STICK" no')
        self.assertEqual(result.returncode, IGNORED, result.stderr)
        self.assertEqual(self.names_in(self.dest), [])
        self.assertIn("left to GNOME", result.stderr)

    @linux_only
    def test_temp_labelled_drive_copies_its_videos_flat_keeping_existing_names(self):
        self.video("Movies/film.mkv", b"film data")
        self.video("Movies/nested/clip.mp4", b"clip data")
        (self.dest / "clip.mp4").write_bytes(b"already mine")
        result = self.run_shell('import_mount "$MP" temp no')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.names_in(self.dest), ["clip.mp4", "film.mkv"])
        self.assertEqual((self.dest / "film.mkv").read_bytes(), b"film data")
        self.assertEqual((self.dest / "clip.mp4").read_bytes(), b"already mine")
        self.assertIn("NOTIFY Videos copied | 1 item(s)", result.stderr)

    @linux_only
    def test_a_disc_copies_its_videos_whatever_its_label(self):
        self.video("film.mkv", b"film data")
        result = self.run_shell('import_mount "$MP" "DISC 1" yes')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.names_in(self.dest), ["film.mkv"])

    # --------------------------------------------------------- releasing media

    def release(self, dev, optical, parent="sdb", transport="usb", removable="1",
                hotplug="1", unmount_ok=True):
        """Runs release_media with the block-device tools stubbed.

        release_media sends their output to /dev/null, so the stubs record what
        they were asked to do in a trace file instead.
        """
        self.trace_file = self.root / "trace.log"
        unmount_status = 0 if unmount_ok else 1
        result = self.run_shell(f'''
TRACE={shlex.quote(str(self.trace_file))}
udisksctl() {{
    printf 'UDISKSCTL %s\\n' "$*" >> "$TRACE"
    case " $* " in *" unmount "*) return {unmount_status} ;; esac
    return 0
}}
eject() {{ printf 'EJECT %s\\n' "$*" >> "$TRACE"; }}
lsblk() {{
    case " $* " in
        *" PKNAME "*)  printf '%s\\n' {shlex.quote(parent)} ;;
        *" TRAN "*)    printf '%s\\n' {shlex.quote(transport)} ;;
        *" RM "*)      printf '%s\\n' {shlex.quote(removable)} ;;
        *" HOTPLUG "*) printf '%s\\n' {shlex.quote(hotplug)} ;;
    esac
}}
release_media {shlex.quote(dev)} {shlex.quote(optical)}
''')
        return result

    def trace(self):
        return self.trace_file.read_text() if self.trace_file.exists() else ""

    def test_a_disc_is_unmounted_then_ejected_never_powered_off(self):
        result = self.release("/dev/sr0", "yes")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("UDISKSCTL unmount --no-user-interaction -b /dev/sr0", self.trace())
        self.assertIn("EJECT /dev/sr0", self.trace())
        self.assertNotIn("power-off", self.trace())

    def test_a_usb_drive_is_unmounted_then_the_whole_disk_powered_off(self):
        result = self.release("/dev/sdb1", "no")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("UDISKSCTL unmount --no-user-interaction -b /dev/sdb1", self.trace())
        # The partition is unmounted, but it is the disk behind it that powers down.
        self.assertIn("UDISKSCTL power-off --no-user-interaction -b /dev/sdb", self.trace())
        self.assertNotIn("EJECT", self.trace())
        self.assertIn("powered down", result.stderr)

    def test_an_internal_drive_is_unmounted_but_left_powered_on(self):
        result = self.release("/dev/sda2", "no", parent="sda", transport="sata",
                              removable="0", hotplug="0")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("UDISKSCTL unmount --no-user-interaction -b /dev/sda2", self.trace())
        self.assertNotIn("power-off", self.trace())
        self.assertIn("not a removable drive", result.stderr)

    def test_a_drive_whose_only_hint_is_hotplug_still_powers_off(self):
        result = self.release("/dev/sdc1", "no", transport="", removable="0", hotplug="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("power-off", self.trace())

    def test_a_failed_unmount_stops_before_ejecting_or_powering_off(self):
        for dev, optical in [("/dev/sr0", "yes"), ("/dev/sdb1", "no")]:
            with self.subTest(dev=dev):
                result = self.release(dev, optical, unmount_ok=False)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertNotIn("EJECT", self.trace())
                self.assertNotIn("power-off", self.trace())
                self.assertIn("Could not unmount", result.stderr)
                self.trace_file.unlink()

    def test_an_unpartitioned_drive_powers_itself_off(self):
        # lsblk gives no PKNAME for whole-disk media, so the device is the disk.
        result = self.release("/dev/sdd", "no", parent="")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("UDISKSCTL power-off --no-user-interaction -b /dev/sdd", self.trace())

    # ------------------------------------------------------------ zip sets

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
            self.age(directory / name)
            names.append(name)
        return names

    def make_span_parts(self):
        """Info-ZIP spanning style: set.z01, set.z02, ..., set.zip"""
        source = self.root / "span-source"
        source.mkdir()
        (source / "movie.mkv").write_bytes(os.urandom(300_000))
        staging = self.root / "span"
        staging.mkdir()
        subprocess.run(["zip", "-q", "-0", "-s", "100k", str(staging / "set.zip"), "movie.mkv"],
                       cwd=source, check=True)
        return staging

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
        parts = self.make_span_parts()
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

    @linux_only
    @unittest.skipUnless(shutil.which("7z"), "7-Zip is required")
    def test_discs_collect_parts_in_temp_then_extract_and_remove_it(self):
        staging = self.root / "all-parts"
        names = self.make_split_parts(staging)
        disc1, disc2 = self.root / "disc1", self.root / "disc2"
        (disc1 / "sub").mkdir(parents=True)
        disc2.mkdir()
        shutil.copy(staging / names[0], disc1 / "sub")
        shutil.copy(staging / names[1], disc1)
        for name in names[1:]:  # Repeats part 2, which must not be copied twice.
            shutil.copy(staging / name, disc2)

        first = self.run_shell(f'import_mount {shlex.quote(str(disc1))} "1" yes')
        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertEqual(self.names_in(self.dest), ["temp"])
        self.assertEqual(self.names_in(self.dest / "temp"), names[:2])
        self.assertIn("NOTIFY Insert the next disc | set.zip still needs set.zip.003.",
                      first.stderr)
        self.assertTrue((disc1 / "sub" / names[0]).exists(), "discs are never modified")

        second = self.run_shell(f'import_mount {shlex.quote(str(disc2))} "2" yes')
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual(self.names_in(self.dest), ["movie.mkv", "notes.txt"])
        self.assertEqual((self.dest / "movie.mkv").read_bytes(), self.movie)
        self.assertIn("NOTIFY set.zip is ready", second.stderr)
        self.assertEqual(list(self.dest.glob(".usb-autorun-*")), [])

    @linux_only
    @unittest.skipUnless(shutil.which("7z"), "7-Zip is required")
    def test_extraction_leaves_existing_names_in_the_destination_alone(self):
        self.make_split_parts(self.source)
        (self.dest / "notes.txt").write_text("mine")
        result = self.run_shell('import_mount "$MP" temp no')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.dest / "notes.txt").read_text(), "mine")
        self.assertEqual((self.dest / "movie.mkv").read_bytes(), self.movie)
        self.assertFalse((self.dest / "temp").exists(), "temp goes once the set is extracted")

    @linux_only
    @unittest.skipUnless(shutil.which("7z"), "7-Zip is required")
    def test_a_second_set_keeps_its_parts_while_the_first_one_extracts(self):
        self.make_split_parts(self.source)
        (self.dest / "temp").mkdir()
        (self.dest / "temp" / "other.zip.001").write_text("part of another set")
        result = self.run_shell('import_mount "$MP" temp no')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.names_in(self.dest / "temp"), ["other.zip.001"])
        self.assertTrue((self.dest / "movie.mkv").exists())

    @linux_only
    @unittest.skipUnless(shutil.which("7z"), "7-Zip is required")
    def test_dotfiles_inside_an_archive_are_extracted_too(self):
        # A plain */ glob over the staging folder would drop these silently.
        self.movie = os.urandom(200_000)
        whole = self.root / "whole.zip"
        with zipfile.ZipFile(whole, "w", zipfile.ZIP_STORED) as archive:
            archive.writestr("movie.mkv", self.movie)
            archive.writestr(".subtitles.srt", "hidden but wanted")
        data = whole.read_bytes()
        for number, start in enumerate(range(0, len(data), 100_000), 1):
            part = self.source / f"set.zip.{number:03d}"
            part.write_bytes(data[start:start + 100_000])
            self.age(part)
        result = self.run_shell('import_mount "$MP" temp no')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.dest / ".subtitles.srt").read_text(), "hidden but wanted")
        self.assertEqual((self.dest / "movie.mkv").read_bytes(), self.movie)

    @linux_only
    @unittest.skipUnless(shutil.which("7z"), "7-Zip is required")
    def test_a_disc_recorded_in_upper_case_is_still_one_set(self):
        staging = self.root / "all-parts"
        self.make_split_parts(staging)
        discs = []
        for number, part in enumerate(sorted(staging.iterdir()), 1):
            disc = self.root / f"disc{number}"
            disc.mkdir()
            shutil.copy(part, disc / part.name.upper())
            self.age(disc / part.name.upper())
            discs.append(disc)
        for disc in discs[:-1]:
            result = self.run_shell(f'import_mount {shlex.quote(str(disc))} "" yes')
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("NOTIFY Insert the next disc", result.stderr)
        last = self.run_shell(f'import_mount {shlex.quote(str(discs[-1]))} "" yes')
        self.assertEqual(last.returncode, 0, last.stderr)
        self.assertEqual((self.dest / "movie.mkv").read_bytes(), self.movie)
        self.assertFalse((self.dest / "temp").exists())

    def test_destination_cannot_be_escaped_with_dot_dot(self):
        result = self.run_shell('DEST="$HOME/Videos/../../etc/cron.d"; validate_destination')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("must live inside", result.stderr)
        self.assertNotIn("Videos/..", result.stderr, "the path is reported folded")

    @linux_only
    def test_collected_parts_are_not_announced_as_copied_videos(self):
        (self.source / "set.zip.001").write_bytes(os.urandom(50_000))
        self.age(self.source / "set.zip.001")
        result = self.run_shell('import_mount "$MP" temp no')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("NOTIFY Insert the next disc", result.stderr)
        self.assertNotIn("NOTIFY Videos copied", result.stderr)

    def test_reset_discards_the_collected_parts(self):
        (self.dest / "temp").mkdir()
        (self.dest / "temp" / "set.zip.001").write_text("part")
        result = self.run_shell("resolve_dest() { :; }; validate_destination() { :; }; reset_temp")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.dest / "temp").exists())
        self.assertEqual(self.names_in(self.dest), [])

    # ------------------------------------------------------------- the rest

    def test_nothing_launches_a_player(self):
        code = [line for line in SCRIPT.read_text().splitlines()
                if not line.lstrip().startswith("#")]
        self.assertNotIn("vlc", "\n".join(code).lower())
        # Kodi may only be named as a package to install or in a message to the
        # user, never run: no JSON-RPC, no systemd-run, no waiting for it.
        for line in code:
            if "kodi" in line.lower():
                self.assertRegex(line, r"dnf |rpmfusion|log |Kodi ", line)
        self.assertNotIn("systemd-run", "\n".join(code))

    def test_mounts_are_handled_once_until_the_media_comes_back(self):
        result = self.run_shell('''
mkdir -p "$STATE_DIR"
printf 'gone\\t/run/media/joao/OLD\\tu1\\n' > "$HANDLED_FILE"
printf 'here\\t%s\\tu2\\n' "$DEST" >> "$HANDLED_FILE"
mountpoint() { [[ ${!#} == "$DEST" ]]; }
findmnt() { printf 'here\\n'; }
prune_handled
cat "$HANDLED_FILE"
already_handled "here"$'\\t'"$DEST"$'\\t'"u2" && echo KEPT
already_handled "gone"$'\\t'"/run/media/joao/OLD"$'\\t'"u1" || echo DROPPED
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("KEPT", result.stdout)
        self.assertIn("DROPPED", result.stdout)

    def test_help_works_without_root(self):
        result = subprocess.run(["bash", str(SCRIPT), "--help"], text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("watch.txt", result.stdout)

    def test_script_parses(self):
        result = subprocess.run(["bash", "-n", str(SCRIPT)], text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
