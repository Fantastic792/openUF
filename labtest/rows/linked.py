"""Hand rows for objects the test WiFi points at (numbers the automatic pass cannot flip). No check yet: the
router change (a tc/nft limit, VLAN 77/78 on the WiFi's bridge) is read from the row's `changed` list."""


def register(checks):
    checks["UserGroup.rate_limit"] = {"set": lambda o: {"qos_rate_max_down": 1000, "qos_rate_max_up": 500}}
    checks["NetworkConf.vlan_77_78"] = {"set": lambda o: {"vlan": 78 if str(o.get("vlan")) == "77" else 77}}
