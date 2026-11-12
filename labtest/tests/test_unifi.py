import os
import tempfile
import unittest
from unittest import mock

from labtest import unifi


def answer(code=200, data=None):
    r = mock.Mock(status_code=code)
    r.json.return_value = {"data": data or []}
    return r


class ControllerTest(unittest.TestCase):
    def setUp(self):
        fd, self.acct = tempfile.mkstemp()
        os.write(fd, b"u\ns3cret-word\n")
        os.close(fd)
        self.conf = {"controller": "https://198.51.100.9:8443", "site": "default", "account_file": self.acct}
        p = mock.patch("requests.Session")
        self.session = p.start().return_value
        self.addCleanup(p.stop)
        self.session.cookies.get.return_value = "T"
        self.session.post.return_value = answer()
        self.session.get.return_value = answer()
        self.session.put.return_value = answer()

    def test_login_posts_the_account(self):
        unifi.Controller(self.conf).login()
        url = self.session.post.call_args[0][0]
        self.assertEqual(url, "https://198.51.100.9:8443/api/login")
        self.assertEqual(self.session.post.call_args[1]["json"], {"username": "u", "password": "s3cret-word"})

    def test_put_sends_the_csrf_token(self):
        unifi.Controller(self.conf).put("rest/wlanconf/1", {"x": 1})
        self.assertEqual(self.session.put.call_args[0][0], "https://198.51.100.9:8443/api/s/default/rest/wlanconf/1")
        self.assertEqual(self.session.put.call_args[1]["headers"]["X-CSRF-Token"], "T")

    def test_get_returns_the_data_list(self):
        self.session.get.return_value = answer(data=[{"_id": "a"}])
        self.assertEqual(unifi.Controller(self.conf).devices(), [{"_id": "a"}])
        self.assertTrue(self.session.get.call_args[0][0].endswith("/api/s/default/stat/device"))

    def test_error_text_never_holds_the_password(self):
        self.session.post.return_value = answer(400)
        with self.assertRaises(RuntimeError) as e:
            unifi.Controller(self.conf).login()
        self.assertIn("400", str(e.exception))
        self.assertNotIn("s3cret-word", str(e.exception))

    def test_force_push_flips_uapsd(self):
        self.session.get.return_value = answer(data=[{"_id": "w1", "uapsd_enabled": False}])
        unifi.Controller(self.conf).force_push("w1")
        self.assertTrue(self.session.put.call_args[0][0].endswith("rest/wlanconf/w1"))
        self.assertEqual(self.session.put.call_args[1]["json"], {"uapsd_enabled": True})

    def test_missing_account_file_is_a_clear_error(self):
        self.conf["account_file"] = self.acct + ".gone"
        with self.assertRaises(RuntimeError) as e:
            unifi.Controller(self.conf).login()
        self.assertIn("account file", str(e.exception))


if __name__ == "__main__":
    unittest.main()
