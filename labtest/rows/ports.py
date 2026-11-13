"""Hand rows for one switch port (`row_port`). A VM has no switch: it can only say sent or not sent (Part 3)."""


def register(checks):
    checks["Device.port_overrides.forward_disabled"] = {"set": lambda o: {"forward": "disabled"}, "risk": "cutoff",
                                                        "needs": "hw"}
