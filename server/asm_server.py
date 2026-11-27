#!/usr/bin/env python3
"""JamSyncXR connection server: rooms and public addresses.

Players behind home routers can't be reached at their own IP. This server
lets them find each other and open direct paths (UDP hole punching):

- The host asks for a room (op "host") and gets a 6-letter code.
- Each of a player's UDP sockets (session/ENet, clock, audio) sends a small
  registration packet ("ASMR" + JSON) to this server, which records the public
  address it came from.
- A joiner asks for the room (op "join"), learns the host's public addresses
  (op "eps"), and connects to them directly. When a joiner's sockets register,
  the host is told (op "punch") so it can send toward them and open its side.

No audio, notes or session data pass through here; it only introduces players.
Python 3.8+, standard library only. Run:  python3 asm_server.py [--port 47900]
"""
import argparse
import json
import secrets
import socket
import time

ROOM_CHARS = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"  # no 0/O or 1/I
ROOM_LEN = 6
ROOM_TTL = 60.0  # seconds without a keepalive from the host
MEMBER_TTL = 60.0
MAX_ROOMS = 2000
MAX_MEMBERS = 6
MAX_PACKET = 1200
KINDS = ("enet", "clock", "audio")


class Server:
    def __init__(self):
        self.rooms = {}  # code -> {"host": token, "members": {token: member}, "t": last host keepalive}

    # ---- helpers
    def _new_code(self):
        while True:
            code = "".join(secrets.choice(ROOM_CHARS) for _ in range(ROOM_LEN))
            if code not in self.rooms:
                return code

    def _member(self, room, token):
        r = self.rooms.get(room)
        if not r or not isinstance(token, str):
            return None, None
        return r, r["members"].get(token)

    def expire(self, now):
        for code in [c for c, r in self.rooms.items() if now - r["t"] > ROOM_TTL]:
            del self.rooms[code]
        for r in self.rooms.values():
            for tok in [t for t, m in r["members"].items() if t != r["host"] and now - m["t"] > MEMBER_TTL]:
                del r["members"][tok]

    # ---- packets
    def handle(self, data, addr, now):
        """Returns a list of (reply_bytes, address)."""
        if len(data) > MAX_PACKET:
            return []
        if data[:4] == b"ASMR":
            return self._register(data[4:], addr, now)
        try:
            msg = json.loads(data.decode("utf-8"))
        except (UnicodeDecodeError, ValueError):
            return []
        if not isinstance(msg, dict):
            return []
        op = msg.get("op")
        if op == "host":
            return self._host(addr, now)
        if op == "join":
            return self._join(msg, addr, now)
        if op == "eps":
            return self._eps(msg, addr)
        if op == "alive":
            return self._alive(msg, addr, now)
        if op == "close":
            r, m = self._member(msg.get("room"), msg.get("token"))
            if r and m:
                if msg.get("token") == r["host"]:
                    del self.rooms[msg["room"]]
                else:
                    del r["members"][msg["token"]]
            return []
        return []

    def _reply(self, obj, addr):
        return [(json.dumps(obj, separators=(",", ":")).encode(), addr)]

    def _host(self, addr, now):
        if len(self.rooms) >= MAX_ROOMS:
            return self._reply({"op": "error", "msg": "The server is full; try again later."}, addr)
        code = self._new_code()
        token = secrets.token_hex(8)
        self.rooms[code] = {"host": token, "t": now,
                            "members": {token: {"ctl": addr, "eps": {}, "t": now}}}
        return self._reply({"op": "hosted", "room": code, "token": token, "you": list(addr)}, addr)

    def _join(self, msg, addr, now):
        code = str(msg.get("room", "")).strip().upper()
        r = self.rooms.get(code)
        if not r:
            return self._reply({"op": "error", "msg": "No room %s. Check the code with the host." % code}, addr)
        if len(r["members"]) >= MAX_MEMBERS:
            return self._reply({"op": "error", "msg": "Room %s is full." % code}, addr)
        token = secrets.token_hex(8)
        r["members"][token] = {"ctl": addr, "eps": {}, "t": now}
        return self._reply({"op": "joined", "room": code, "token": token, "you": list(addr)}, addr)

    def _eps(self, msg, addr):
        r, m = self._member(msg.get("room"), msg.get("token"))
        if not m:
            return self._reply({"op": "error", "msg": "Not in that room."}, addr)
        who = msg.get("who", "host")
        target = r["host"] if who == "host" else (msg.get("token") if who == "me" else who)
        tm = r["members"].get(target)
        eps = {k: list(v) for k, v in tm["eps"].items()} if tm else {}
        return self._reply({"op": "eps", "who": who, "eps": eps}, addr)

    def _alive(self, msg, addr, now):
        r, m = self._member(msg.get("room"), msg.get("token"))
        if not m:
            return self._reply({"op": "error", "msg": "Room closed."}, addr)
        m["t"] = now
        m["ctl"] = addr
        if msg.get("token") == r["host"]:
            r["t"] = now
        return []

    def _register(self, body, addr, now):
        try:
            reg = json.loads(body.decode("utf-8"))
        except (UnicodeDecodeError, ValueError):
            return []
        if not isinstance(reg, dict) or reg.get("kind") not in KINDS:
            return []
        r, m = self._member(reg.get("room"), reg.get("token"))
        if not m:
            return []
        kind = reg["kind"]
        changed = m["eps"].get(kind) != addr
        m["eps"][kind] = addr
        m["t"] = now
        out = []
        # Tell the host about a joiner's socket, so it can punch toward it.
        if changed and reg["token"] != r["host"]:
            host = r["members"].get(r["host"])
            if host:
                out += self._reply({"op": "punch", "token": reg["token"],
                                    "eps": {k: list(v) for k, v in m["eps"].items()}}, host["ctl"])
        return out


def serve(port, bind=""):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind((bind, port))
    sock.settimeout(1.0)
    srv = Server()
    print("JamSyncXR connection server on UDP %s:%d" % (bind or "*", port), flush=True)
    last_expire = time.monotonic()
    while True:
        try:
            data, addr = sock.recvfrom(2048)
        except socket.timeout:
            data = None
        except ConnectionResetError:  # Windows: ICMP port unreachable from an earlier send
            continue
        now = time.monotonic()
        if data:
            for reply, to in srv.handle(data, addr, now):
                try:
                    sock.sendto(reply, to)
                except OSError:
                    pass
        if now - last_expire > 5.0:
            srv.expire(now)
            last_expire = now


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--port", type=int, default=47900)
    ap.add_argument("--bind", default="")
    a = ap.parse_args()
    serve(a.port, a.bind)
