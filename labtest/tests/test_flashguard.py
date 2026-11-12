import os
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

    def test_real_tree_is_clean(self):
        self.assertEqual(flashguard.scan(REPO), [])


if __name__ == "__main__":
    unittest.main()
