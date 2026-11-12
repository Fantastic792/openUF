import os
import subprocess
import tempfile
import unittest

from labtest.safety import flashguard

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

HITS = ['os.execute("sysupgrade -n /tmp/fw.bin")', 'mtd -r write /tmp/x firmware',
        'fw_setenv bootcount 0', 'ubiformat /dev/ubi0', 'dd if=x of=/dev/mtdblock3', 'cat /dev/mtd2']
CLEAN = ['-- owns it through boot, failsafe and sysupgrade',
         'echo "Registered $keep with sysupgrade (survives a firmware upgrade)."',
         'SYSUPGRADE_CONF=/etc/sysupgrade.conf', 'x = 1 -- mtd write would be bad']


class FlashGuardTest(unittest.TestCase):
    def test_each_forbidden_call_is_found(self):
        for s in HITS:
            for name in ("a.lua", "a.sh"):
                self.assertEqual(len(flashguard.scan_text(name, s)), 1, (name, s))

    def test_comments_and_prose_are_not_hits(self):
        for s in CLEAN:
            name = "a.lua" if s.startswith("-- ") or " -- " in s else "a.sh"
            self.assertEqual(flashguard.scan_text(name, s), [], s)

    def test_shell_comment_is_not_a_hit(self):
        self.assertEqual(flashguard.scan_text("a.sh", "true # fw_setenv x"), [])
        self.assertEqual(flashguard.scan_text("a.sh", "# mtd write x y"), [])

    def test_js_comment_is_not_a_hit(self):
        self.assertEqual(flashguard.scan_text("a.js", "x(); // fw_setenv x"), [])

    def test_file_with_no_extension_is_scanned(self):
        self.assertEqual(len(flashguard.scan_text("package/openuf/files/hook", "fw_setenv a b")), 1)

    def test_hit_reports_path_and_line_number(self):
        self.assertEqual(flashguard.scan_text("f.sh", "ok\nfw_setenv a b\n"), [("f.sh", 2, "fw_setenv a b")])

    def test_mtd_option_with_an_argument_is_found(self):
        self.assertEqual(len(flashguard.scan_text("a.sh", "mtd -e linux write /tmp/x linux")), 1)

    def test_sysupgrade_with_a_variable_is_found(self):
        for s in ('sysupgrade "$IMG"', "sysupgrade $IMG"):
            self.assertEqual(len(flashguard.scan_text("a.sh", s)), 1, s)

    def test_other_flash_tools_are_found(self):
        for s in ("flashcp x /dev/x", "flash_erase /dev/x 0 0", "nandwrite -p /dev/x f", "ubiupdatevol /dev/x f"):
            self.assertEqual(len(flashguard.scan_text("a.sh", s)), 1, s)

    def test_odd_names_and_non_utf8_files_are_scanned(self):
        repo = tempfile.mkdtemp()
        os.makedirs(os.path.join(repo, "openuf"))
        with open(os.path.join(repo, "openuf", "a b.sh"), "w") as f:
            f.write("fw_setenv a b\n")
        with open(os.path.join(repo, "openuf", "latin"), "wb") as f:
            f.write(b"# caf\xe9\nfw_setenv a b\n")
        subprocess.run(["git", "-C", repo, "init", "-q"], check=True)
        subprocess.run(["git", "-C", repo, "add", "."], check=True)
        self.assertEqual(sorted(p for p, _, _ in flashguard.scan(repo)), ["openuf/a b.sh", "openuf/latin"])

    def test_real_tree_is_clean(self):
        self.assertEqual(flashguard.scan(REPO), [])


if __name__ == "__main__":
    unittest.main()
