"""Real checks for WLAN rows: what every hostapd block of the WLAN must show after the push."""
PMF = ["disabled", "optional", "required"]


def _val(block, name):
    return next((line.split("=", 1)[1] for line in block if line.startswith(name + "=")), None)


def _every(blocks, test, what):
    if not blocks:
        return False, "no hostapd block for the WLAN"
    bad = [_val(b, what.split("=")[0]) for b in blocks if not test(b)]
    return (not bad), (f"{len(bad)} of {len(blocks)} blocks: {what.split('=')[0]}={bad[0]}" if bad else "")


def _flag(key, line):
    def check(blocks, new):
        if new[key]:
            return _every(blocks, lambda b: _val(b, line) == "1", f"{line}=1")
        return _every(blocks, lambda b: _val(b, line) in (None, "0"), f"{line}=0")
    return {"set": lambda o: {key: not o.get(key, False)}, "check": check}


def _enabled(blocks, new):
    if new["enabled"]:
        return (True, "") if blocks else (False, "no hostapd block for the WLAN")
    return (not blocks), (f"{len(blocks)} blocks still up" if blocks else "")


def _pmf_set(o):
    cur = o.get("pmf_mode", "disabled")
    return {"pmf_mode": PMF[(PMF.index(cur) + 1) % 3 if cur in PMF else 1]}


def _pmf(blocks, new):
    want = str(PMF.index(new["pmf_mode"]))
    return _every(blocks, lambda b: (_val(b, "ieee80211w") or "0") == want, f"ieee80211w={want}")


def _rekey(blocks, new):
    want = str(new["group_rekey"])
    return _every(blocks, lambda b: _val(b, "wpa_group_rekey") == want, f"wpa_group_rekey={want}")


def _dtim_set(o):
    v = 2 if o.get("dtim_na") == 3 else 3
    return {"dtim_mode": "custom", "dtim_na": v, "dtim_ng": v}


def _dtim(blocks, new):
    want = str(new["dtim_na"])
    return _every(blocks, lambda b: _val(b, "dtim_period") == want, f"dtim_period={want}")


def _ft(blocks, new):
    def has_ft(b):
        return _val(b, "mobility_domain") is not None and "FT-" in (_val(b, "wpa_key_mgmt") or "")

    def no_ft(b):
        return _val(b, "mobility_domain") is None and "FT-" not in (_val(b, "wpa_key_mgmt") or "")
    if new["fast_roaming_enabled"]:
        return _every(blocks, has_ft, "mobility_domain=+FT-")
    return _every(blocks, no_ft, "mobility_domain=none")


def register(checks):
    checks.update({
        "WlanConf.enabled": {"set": lambda o: {"enabled": not o.get("enabled", False)}, "check": _enabled},
        "WlanConf.hide_ssid": _flag("hide_ssid", "ignore_broadcast_ssid"),
        "WlanConf.uapsd_enabled": _flag("uapsd_enabled", "uapsd_advertisement_enabled"),
        "WlanConf.l2_isolation": _flag("l2_isolation", "ap_isolate"),
        "WlanConf.pmf_mode": {"set": _pmf_set, "check": _pmf},
        "WlanConf.group_rekey": {"set": lambda o: {"group_rekey": 3600 if o.get("group_rekey") == 7200 else 7200},
                                 "check": _rekey},
        "WlanConf.dtim": {"set": _dtim_set, "check": _dtim},
        "WlanConf.fast_roaming_enabled": {"set": lambda o: {"fast_roaming_enabled": not o.get("fast_roaming_enabled",
                                                                                               False)},
                                          "check": _ft},
    })
