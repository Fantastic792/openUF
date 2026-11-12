"""Small UniFi controller API client for the LAB controller. The password is read from the
account file and never printed, logged or put in an error text."""
import requests
import urllib3

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)  # lab controller: self-signed cert


class Controller:
    def __init__(self, conf):
        self.base, self.site, self.account_file = conf["controller"].rstrip("/"), conf["site"], conf["account_file"]
        self.s = requests.Session()
        self.s.verify = False

    def _check(self, r, path):
        if r.status_code != 200:
            raise RuntimeError(f"controller: HTTP {r.status_code} on {path}")  # never the body
        return r

    def _headers(self):
        token = self.s.cookies.get("csrf_token")
        return {"X-CSRF-Token": token} if token else {}

    def login(self):
        try:
            with open(self.account_file) as f:
                user, password = f.read().splitlines()[:2]
        except (OSError, ValueError):
            raise RuntimeError("controller: account file missing or not two lines (user, password)") from None
        self._check(self.s.post(f"{self.base}/api/login", json={"username": user, "password": password},
                                headers=self._headers()), "/api/login")

    def _url(self, path):
        return f"{self.base}/api/s/{self.site}/{path}"

    def get(self, path):
        return self._check(self.s.get(self._url(path)), path).json()["data"]

    def put(self, path, body):
        return self._check(self.s.put(self._url(path), json=body, headers=self._headers()), path).json()["data"]

    def wlans(self):
        return self.get("rest/wlanconf")

    def devices(self):
        return self.get("stat/device")

    def force_push(self, wlan_id):
        w = next(w for w in self.wlans() if w["_id"] == wlan_id)
        self.put(f"rest/wlanconf/{wlan_id}", {"uapsd_enabled": not w.get("uapsd_enabled", False)})
