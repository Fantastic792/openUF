"""A lab VM dressed as a JioRouter AX6000 JIDU6J01: board name at boot, five veth ports in br-lan."""

BOARD = "jiorouter,ax6000-jidu6j01"
MODEL = "JioRouter AX6000 JIDU6J01"
PORTS = ["lan1", "lan2", "lan3", "lan4", "wan"]  # list position + 1 = port idx in openUF's map
FAR_BRIDGE = "br-far"
INIT = "/etc/init.d/fakeboard"

BOOT_SCRIPT = f"""#!/bin/sh /etc/rc.common
# labtest fake board: not part of openUF, removed by a VM reset
START=15
boot() {{
\tmkdir -p /tmp/sysinfo
\techo '{BOARD}' > /tmp/sysinfo/board_name
\techo '{MODEL}' > /tmp/sysinfo/model
}}
"""


def far(port):
    return port + "p"


def macs(base):
    tail = "02:" + ":".join(base.split(":")[2:6]) + ":"  # 02: locally administered, then bytes 3-6 of base
    m = {"br-lan": base, "eth0": tail + "e0"}
    for i, p in enumerate(PORTS, 1):
        m[p], m[far(p)] = tail + f"{i:02x}", tail + f"{0x10 + i:02x}"
    return m


def uci_batch(base, uplink="lan1"):
    m = macs(base)
    b = [f"set network.@device[0].macaddr='{base}'", "delete network.@device[0].ports"]
    b += [f"add_list network.@device[0].ports='{p}'" for p in PORTS]
    b += ["set network.fb_eth0=device", "set network.fb_eth0.name='eth0'", f"set network.fb_eth0.macaddr='{m['eth0']}'"]
    for p in PORTS:
        b += [f"set network.fb_{p}=device", f"set network.fb_{p}.name='{p}'", f"set network.fb_{p}.type='veth'",
              f"set network.fb_{p}.peer_name='{far(p)}'", f"set network.fb_{p}.macaddr='{m[p]}'",
              f"set network.fb_{p}.peer_macaddr='{m[far(p)]}'"]
    b += ["set network.fb_far=device", f"set network.fb_far.name='{FAR_BRIDGE}'", "set network.fb_far.type='bridge'",
          "add_list network.fb_far.ports='eth0'", f"add_list network.fb_far.ports='{far(uplink)}'",
          "set network.fb_farif=interface", f"set network.fb_farif.device='{FAR_BRIDGE}'",
          "set network.fb_farif.proto='none'"]
    for p in PORTS:
        if p != uplink:  # an interface keeps the far end up: cable plugged
            b += [f"set network.fb_{far(p)}=interface", f"set network.fb_{far(p)}.device='{far(p)}'",
                  f"set network.fb_{far(p)}.proto='none'"]
    return "\n".join(b + ["commit network"]) + "\n"
