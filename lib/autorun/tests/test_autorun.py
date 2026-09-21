"""Non-destructive tests: real temp-directory transfers, mocked host services."""
import os
from pathlib import Path
import platform
import shlex
import shutil
import subprocess
import tempfile
import unittest


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
user_systemctl() {{ :; }}
"""
        if platform.system() != "Linux":
            # GNU sync -f is Linux-specific; test its error handling below.
            setup += 'sync() { :; }\n'
        return subprocess.run(["bash", "-c", setup + body], text=True,
                              capture_output=True)

    def test_success_copies_hidden_files_replaces_old_and_erases_usb(self):
        result = self.run_shell('import_contents "$MP"')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.dest / "new video.mp4").read_bytes(), b"new video data")
        self.assertEqual((self.dest / ".hidden").read_text(), "also copied")
        self.assertFalse((self.dest / "old.mp4").exists())
        self.assertEqual(list(self.source.iterdir()), [])

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

    def test_symlink_on_usb_is_rejected_before_deletion(self):
        (self.source / "outside").symlink_to(self.dest, target_is_directory=True)
        result = self.run_shell('import_contents "$MP"')
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((self.source / "new video.mp4").exists())
        self.assertTrue((self.dest / "old.mp4").exists())
        self.assertIn("regular files", result.stderr.lower())

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
        show-environment) printf '%s\\n' WAYLAND_DISPLAY=wayland-0 {'DISPLAY=:1' if display else 'HOME=/home/desktop'} ;;
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
            ({"display": False}, "DISPLAY"),
        ]:
            with self.subTest(options=options):
                result = self.run_shell(self.session_fixture(**options))
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(message, result.stderr)

    def test_unsafe_destination_rejected(self):
        for dest in ["/", "/home", "/home/../etc", "/srv", "/etc", "/home/a/b"]:
            with self.subTest(dest=dest):
                result = self.run_shell(f'DEST={shlex.quote(dest)}; validate_destination')
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("destination", result.stderr.lower())

    def test_help_works_without_root(self):
        result = subprocess.run(["bash", str(SCRIPT), "--help"],
                                text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--user", result.stdout)


if __name__ == "__main__":
    unittest.main()
