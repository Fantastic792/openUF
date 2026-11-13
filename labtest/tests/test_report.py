import unittest

from labtest import report


class ReportTest(unittest.TestCase):
    def test_markdown_puts_broken_first_and_counts_on_top(self):
        result = {"pass": False, "counts": {"broken": 1, "ignored": 1, "not_covered": 0, "not_sent": 0, "works": 1},
                  "rows": [{"name": "A.ok", "result": "works", "note": "", "sent": [], "changed": []},
                           {"name": "A.bad", "result": "broken", "note": "lua error | x", "sent": ["+a=1"],
                            "changed": ["uci: +1", "uci: +2", "uci: +3", "uci: +4", "uci: +5"]},
                           {"name": "A.ign", "result": "ignored", "note": "", "sent": ["+b=1"], "changed": [],
                            "also_changed": ["wlan_band"]}],
                  "commit": "abc1234", "date": "2026-01-01T00:00:00"}
        md = report.markdown(result)
        top = md.split("##")[0]
        self.assertIn("3 rows: 1 broken, 1 ignored, 0 not covered, 0 not sent, 1 works", top)
        self.assertIn("abc1234", top)
        self.assertLess(md.index("A.bad"), md.index("A.ign"))
        self.assertLess(md.index("A.ign"), md.index("A.ok"))
        self.assertIn("+2 more", md)
        self.assertIn("lua error \\| x", md)  # a pipe in a note does not break the table
        self.assertNotIn("## Not covered", md)  # empty groups are left out
        self.assertIn("| A.ign |  | +b=1 |  | wlan_band |", md)  # fields the controller changed itself
        self.assertIn("| A.ok |  |  |  |  |", md)  # rows from before also_changed existed still render
        self.assertNotIn("Waits for hardware", md)

    def test_hw_rows_listed_apart(self):
        result = {"pass": True, "counts": {"not_sent": 1}, "rows": [
            {"name": "Device.port_overrides.forward", "result": "not_sent", "note": "", "sent": [], "changed": [],
             "needs": "hw"}]}
        self.assertIn("## Waits for hardware (1)\n\nDevice.port_overrides.forward", report.markdown(result))


if __name__ == "__main__":
    unittest.main()
