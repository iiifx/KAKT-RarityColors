#!/usr/bin/env python3
"""Tests for installer/kakt_mod.sh and installer/kakt_mod.ps1 on a fake game folder.

    python3 tests/test_installer.py            # sh implementation (Linux, macOS)
    KAKT_IMPL=ps python3 tests/test_installer.py   # PowerShell implementation (Windows)
    KAKT_SH=bash python3 tests/test_installer.py   # sh implementation under another shell

The fixture never touches a real game: it builds a fake Steam library in a temporary folder
whose paths contain spaces and apostrophes. Interactive questions are not tested: with stdin
redirected the scripts behave as non-interactive, which the tests rely on.
"""
import hashlib, os, shutil, subprocess, sys, tempfile, unittest

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
IMPL = os.environ.get("KAKT_IMPL", "ps" if os.name == "nt" else "sh")
SCRIPT = "kakt_mod." + {"sh": "sh", "ps": "ps1"}[IMPL]
BUILD = "18532639"

VANILLA = {
    "KA_KT.exe": b"exe",
    "Cfg/a.cfg": b"a = vanilla\r\n",
    "Cfg/GUI/Styles.xml": b"<Styles>vanilla</Styles>\r\n",
    "UI/Items/x.dds": bytes(range(256)) * 4,
    "Strings/Eng/Langs/names.xml": b"<name>Sword</name>\r\n",
    "Cfg/other.cfg": b"other = vanilla\r\n",
}
MOD = {  # source path in the mod -> content
    "Cfg/a.cfg": b"a = mod\r\n",
    "Cfg/GUI/Styles.xml": b"<Styles>mod</Styles>\r\n",
    "UI/Items/x.dds": bytes(reversed(range(256))) * 4,
    "Cfg/new.cfg": b"new file added by the mod\r\n",
    "Optional/Extra/Strings/Eng/Langs/names.xml": b"<name>[T1] Sword</name>\r\n",
}
OTHER_MOD = {"Cfg/other.cfg": b"other = mod\r\n"}


def sha(data):
    return hashlib.sha256(data).hexdigest()


def target_of(src):
    parts = src.split("/")
    return ("/".join(parts[2:]), parts[1]) if parts[0] == "Optional" else (src, "core")


def make_mod(folder, name, files, warning=None):
    os.makedirs(os.path.join(folder, "installer"))
    shutil.copy(os.path.join(REPO, "installer", SCRIPT), os.path.join(folder, "installer", SCRIPT))
    lines = ["mod\t" + name, "version\t1.0", "buildid\t" + BUILD]
    if warning:
        lines.append("uninstall_warning\t" + warning)
    for src, data in files.items():
        target, component = target_of(src)
        write(os.path.join(folder, src), data)
        vanilla = sha(VANILLA[target]) if target in VANILLA else "-"
        lines.append("\t".join(["file", component, src, target, vanilla, sha(data)]))
    with open(os.path.join(folder, "installer", "manifest.txt"), "w", newline="\n") as f:
        f.write("\n".join(lines) + "\n")


def write(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(data)


def read(path):
    with open(path, "rb") as f:
        return f.read()


class InstallerTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="kakt test ")
        lib = os.path.join(self.tmp, "Steam's Library")
        self.game = os.path.join(lib, "steamapps", "common", "King Arthur Knight's Tale")
        for rel, data in VANILLA.items():
            write(os.path.join(self.game, rel), data)
        write(os.path.join(lib, "steamapps", "appmanifest_1157390.acf"),
              ('"AppState"\n{\n\t"appid"\t\t"1157390"\n\t"buildid"\t\t"%s"\n}\n' % BUILD).encode())
        self.acf = os.path.join(lib, "steamapps", "appmanifest_1157390.acf")
        self.mod = os.path.join(self.tmp, "Mod's Folder")
        make_mod(self.mod, "TestMod", MOD)
        self.other = os.path.join(self.tmp, "Other Mod")
        make_mod(self.other, "OtherMod", OTHER_MOD)
        self.backup = os.path.join(self.game, "_mod_backups", "TestMod")

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    # helpers

    def run_mod(self, action, *args, mod=None, env=None):
        script = os.path.join(mod or self.mod, "installer", SCRIPT)
        if IMPL == "sh":
            cmd = [os.environ.get("KAKT_SH", "sh"), script]
        else:
            cmd = [os.environ.get("KAKT_PS", "powershell"), "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", script]
        full_env = dict(os.environ, KAKT_FAKE_RUNNING="0")
        full_env.update(env or {})
        p = subprocess.run(cmd + [action, "--game", self.game] + list(args), stdin=subprocess.DEVNULL,
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=full_env)
        out = p.stdout.decode("utf-8", "replace")
        return p.returncode, out

    def game_file(self, rel):
        path = os.path.join(self.game, rel)
        return read(path) if os.path.exists(path) else None

    def assert_vanilla(self):
        for rel, data in VANILLA.items():
            self.assertEqual(self.game_file(rel), data, rel)
        self.assertIsNone(self.game_file("Cfg/new.cfg"))

    def assert_core_installed(self):
        for src, data in MOD.items():
            target, component = target_of(src)
            if component == "core":
                self.assertEqual(self.game_file(target), data, target)

    def snapshot(self):
        result = {}
        for base, _, files in os.walk(self.game):
            for f in files:
                path = os.path.join(base, f)
                result[os.path.relpath(path, self.game)] = read(path)
        return result

    # scenarios

    def test_install_uninstall(self):
        code, out = self.run_mod("install")
        self.assertEqual(code, 0, out)
        self.assert_core_installed()
        self.assertEqual(self.game_file("Strings/Eng/Langs/names.xml"), VANILLA["Strings/Eng/Langs/names.xml"])
        self.assertEqual(read(os.path.join(self.backup, "files", "Cfg", "a.cfg")), VANILLA["Cfg/a.cfg"])
        self.assertIn("installed", read(os.path.join(self.backup, "state.txt")).decode())
        code, out = self.run_mod("uninstall")
        self.assertEqual(code, 0, out)
        self.assert_vanilla()
        self.assertFalse(os.path.exists(os.path.join(self.game, "_mod_backups")))

    def test_install_twice_is_noop(self):
        self.run_mod("install")
        before = self.snapshot()
        code, out = self.run_mod("install")
        self.assertEqual(code, 0, out)
        self.assertIn("already installed", out)
        self.assertEqual(self.snapshot(), before)

    def test_manual_install_refused(self):
        write(os.path.join(self.game, "Cfg/a.cfg"), MOD["Cfg/a.cfg"])
        before = self.snapshot()
        code, out = self.run_mod("install")
        self.assertEqual(code, 1, out)
        self.assertIn("by hand", out)
        self.assertEqual(self.snapshot(), before)

    def test_foreign_file_refused_then_forced(self):
        write(os.path.join(self.game, "Cfg/a.cfg"), b"someone else's change\r\n")
        before = self.snapshot()
        code, out = self.run_mod("install")
        self.assertEqual(code, 1, out)
        self.assertEqual(self.snapshot(), before)
        code, out = self.run_mod("install", "--force")
        self.assertEqual(code, 0, out)
        self.assertEqual(self.game_file("Cfg/a.cfg"), MOD["Cfg/a.cfg"])
        code, out = self.run_mod("uninstall")
        self.assertEqual(code, 0, out)
        self.assertEqual(self.game_file("Cfg/a.cfg"), b"someone else's change\r\n")

    def test_missing_target_refused(self):
        os.remove(os.path.join(self.game, "Cfg/a.cfg"))
        before = self.snapshot()
        code, out = self.run_mod("install")
        self.assertEqual(code, 1, out)
        self.assertEqual(self.snapshot(), before)

    def test_damaged_source_refused(self):
        write(os.path.join(self.mod, "UI/Items/x.dds"), b"truncated")
        code, out = self.run_mod("install")
        self.assertEqual(code, 1, out)
        self.assertIn("damaged", out)
        self.assert_vanilla()
        self.assertFalse(os.path.exists(os.path.join(self.game, "_mod_backups")))

    def test_game_update_after_install(self):
        self.run_mod("install")
        write(os.path.join(self.game, "Cfg/a.cfg"), b"a = patched by the game update\r\n")
        write(self.acf, read(self.acf).replace(BUILD.encode(), b"99999999"))
        code, out = self.run_mod("install")
        self.assertEqual(code, 1, out)
        self.assertIn("uninstaller first", out)
        code, out = self.run_mod("uninstall")
        self.assertEqual(code, 2, out)
        self.assertIn("updated", out)
        self.assertEqual(self.game_file("Cfg/a.cfg"), b"a = patched by the game update\r\n")
        self.assertEqual(self.game_file("Cfg/GUI/Styles.xml"), VANILLA["Cfg/GUI/Styles.xml"])
        self.assertIsNone(self.game_file("Cfg/new.cfg"))
        self.assertTrue(os.path.exists(os.path.join(self.backup, "state.txt")))
        code, out = self.run_mod("install")
        self.assertEqual(code, 1, out)
        self.assertIn("--discard-backup", out)
        code, out = self.run_mod("uninstall", "--discard-backup")
        self.assertEqual(code, 2, out)
        self.assertFalse(os.path.exists(os.path.join(self.game, "_mod_backups")))

    def test_copy_failure_rolls_back(self):
        code, out = self.run_mod("install", env={"KAKT_FAIL_AFTER": "2"})
        self.assertEqual(code, 1, out)
        self.assert_vanilla()
        self.assertFalse(os.path.exists(os.path.join(self.game, "_mod_backups")))

    def test_failed_rollback_keeps_backup(self):
        code, out = self.run_mod("install", env={"KAKT_FAIL_AFTER": "2", "KAKT_FAIL_RESTORE": "1"})
        self.assertEqual(code, 1, out)
        self.assertIn("backup is kept", out)
        self.assertIn("installing", read(os.path.join(self.backup, "state.txt")).decode())
        code, out = self.run_mod("uninstall")
        self.assertEqual(code, 0, out)
        self.assert_vanilla()
        self.assertFalse(os.path.exists(os.path.join(self.game, "_mod_backups")))

    def test_yes_does_not_add_optional_components(self):
        code, out = self.run_mod("install", "--yes")
        self.assertEqual(code, 0, out)
        self.assertEqual(self.game_file("Strings/Eng/Langs/names.xml"), VANILLA["Strings/Eng/Langs/names.xml"])

    def test_other_version_installed(self):
        self.run_mod("install")
        manifest = os.path.join(self.mod, "installer", "manifest.txt")
        write(manifest, read(manifest).replace(b"version\t1.0", b"version\t1.1"))
        code, out = self.run_mod("install")
        self.assertEqual(code, 1, out)
        self.assertIn("uninstaller before installing 1.1", out)
        code, out = self.run_mod("uninstall")
        self.assertEqual(code, 0, out)
        self.assert_vanilla()

    def test_crash_during_copy(self):
        code, out = self.run_mod("install", env={"KAKT_CRASH_AFTER": "2"})
        self.assertEqual(code, 99, out)
        code, out = self.run_mod("install")
        self.assertEqual(code, 1, out)
        self.assertIn("did not finish", out)
        code, out = self.run_mod("uninstall")
        self.assertEqual(code, 0, out)
        self.assert_vanilla()
        self.assertFalse(os.path.exists(os.path.join(self.game, "_mod_backups")))

    def test_stray_backup_without_state(self):
        write(os.path.join(self.backup, "files", "Cfg", "a.cfg"), b"junk")
        code, out = self.run_mod("install")
        self.assertEqual(code, 0, out)
        self.assertEqual(read(os.path.join(self.backup, "files", "Cfg", "a.cfg")), VANILLA["Cfg/a.cfg"])

    def test_steam_verify_then_install(self):
        self.run_mod("install")
        for rel, data in VANILLA.items():
            write(os.path.join(self.game, rel), data)
        os.remove(os.path.join(self.game, "Cfg/new.cfg"))
        code, out = self.run_mod("install")
        self.assertEqual(code, 0, out)
        self.assert_core_installed()
        code, out = self.run_mod("uninstall")
        self.assertEqual(code, 0, out)
        self.assert_vanilla()

    def test_optional_component(self):
        code, out = self.run_mod("install", "--with", "Extra")
        self.assertEqual(code, 0, out)
        self.assertEqual(self.game_file("Strings/Eng/Langs/names.xml"), MOD["Optional/Extra/Strings/Eng/Langs/names.xml"])
        code, out = self.run_mod("uninstall")
        self.assertEqual(code, 0, out)
        self.assert_vanilla()

    def test_optional_component_later(self):
        self.run_mod("install")
        code, out = self.run_mod("install", "--with", "Extra")
        self.assertEqual(code, 1, out)
        self.assertIn("without Extra", out)

    def test_unknown_component(self):
        code, out = self.run_mod("install", "--with", "Nope")
        self.assertEqual(code, 1, out)
        self.assert_vanilla()

    def test_two_mods(self):
        self.assertEqual(self.run_mod("install")[0], 0)
        self.assertEqual(self.run_mod("install", mod=self.other)[0], 0)
        code, out = self.run_mod("uninstall")
        self.assertEqual(code, 0, out)
        self.assertEqual(self.game_file("Cfg/other.cfg"), OTHER_MOD["Cfg/other.cfg"])
        self.assertEqual(self.game_file("Cfg/a.cfg"), VANILLA["Cfg/a.cfg"])
        code, out = self.run_mod("uninstall", mod=self.other)
        self.assertEqual(code, 0, out)
        self.assert_vanilla()

    def test_uninstall_not_installed(self):
        code, out = self.run_mod("uninstall")
        self.assertEqual(code, 0, out)
        self.assertIn("not installed", out)

    def test_game_running(self):
        code, out = self.run_mod("install", env={"KAKT_FAKE_RUNNING": "1"})
        self.assertEqual(code, 1, out)
        self.assert_vanilla()

    def test_uninstall_warning_needs_confirmation(self):
        warned = os.path.join(self.tmp, "Warned Mod")
        make_mod(warned, "WarnedMod", {"Cfg/a.cfg": MOD["Cfg/a.cfg"]}, warning="Removing it mid-campaign may break things.")
        self.assertEqual(self.run_mod("install", mod=warned)[0], 0)
        code, out = self.run_mod("uninstall", mod=warned)
        self.assertEqual(code, 1, out)
        self.assertIn("mid-campaign", out)
        self.assertEqual(self.game_file("Cfg/a.cfg"), MOD["Cfg/a.cfg"])
        code, out = self.run_mod("uninstall", "--yes", mod=warned)
        self.assertEqual(code, 0, out)
        self.assert_vanilla()

    def test_build_mismatch_warns(self):
        write(self.acf, read(self.acf).replace(BUILD.encode(), b"99999999"))
        code, out = self.run_mod("install")
        self.assertEqual(code, 0, out)
        self.assertIn("WARNING", out)

    @unittest.skipIf(IMPL == "ps" and os.name != "nt", ".bat launchers need Windows")
    def test_launchers(self):
        # the double-click launchers next to installer/, run from a folder with an apostrophe
        for name in ("install", "uninstall"):
            ext = "bat" if IMPL == "ps" else "sh"
            shutil.copy(os.path.join(REPO, name + "." + ext), os.path.join(self.mod, name + "." + ext))
        env = dict(os.environ, KAKT_FAKE_RUNNING="0", KAKT_NOPAUSE="1")
        for name in ("install", "uninstall"):
            if IMPL == "ps":
                bat = os.path.join(self.mod, name + ".bat")
                p = subprocess.run('cmd /s /c ""%s" --game "%s""' % (bat, self.game), stdin=subprocess.DEVNULL,
                                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=env)
            else:
                p = subprocess.run([os.environ.get("KAKT_SH", "sh"), os.path.join(self.mod, name + ".sh"), "--game", self.game],
                                   stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=env)
            self.assertEqual(p.returncode, 0, p.stdout.decode("utf-8", "replace"))
            if name == "install":
                self.assert_core_installed()
        self.assert_vanilla()

    def test_not_a_game_folder(self):
        self.game = self.tmp
        code, out = self.run_mod("install")
        self.assertEqual(code, 1, out)


if __name__ == "__main__":
    print("implementation:", IMPL)
    unittest.main(verbosity=2)
