"""Unit tests for the connection server's room logic (no sockets)."""
import json
import unittest

from asm_server import ROOM_TTL, Server


def j(replies):
    return [(json.loads(b), a) for b, a in replies]


class ServerTest(unittest.TestCase):
    def setUp(self):
        self.s = Server()
        self.host_ctl = ("203.0.113.5", 40000)
        out = j(self.s.handle(b'{"op":"host"}', self.host_ctl, 0.0))
        self.room = out[0][0]["room"]
        self.host_tok = out[0][0]["token"]

    def reg(self, token, kind, addr, t=0.0):
        body = json.dumps({"room": self.room, "token": token, "kind": kind}).encode()
        return j(self.s.handle(b"ASMR" + body, addr, t))

    def test_room_code_shape(self):
        self.assertEqual(len(self.room), 6)
        self.assertTrue(all(c not in "01OI" for c in self.room))

    def test_join_and_learn_host_addresses(self):
        self.reg(self.host_tok, "enet", ("203.0.113.5", 47830))
        self.reg(self.host_tok, "clock", ("203.0.113.5", 47831))
        joined = j(self.s.handle(json.dumps({"op": "join", "room": self.room.lower()}).encode(), ("198.51.100.7", 5000), 1.0))[0][0]
        self.assertEqual(joined["op"], "joined")
        eps = j(self.s.handle(json.dumps({"op": "eps", "room": self.room, "token": joined["token"], "who": "host"}).encode(), ("198.51.100.7", 5000), 1.0))[0][0]
        self.assertEqual(eps["eps"], {"enet": ["203.0.113.5", 47830], "clock": ["203.0.113.5", 47831]})

    def test_host_is_told_to_punch_toward_joiner(self):
        joined = j(self.s.handle(json.dumps({"op": "join", "room": self.room}).encode(), ("198.51.100.7", 5000), 1.0))[0][0]
        out = self.reg(joined["token"], "enet", ("198.51.100.7", 61000))
        self.assertEqual(len(out), 1)
        msg, to = out[0]
        self.assertEqual(to, self.host_ctl)
        self.assertEqual(msg["op"], "punch")
        self.assertEqual(msg["eps"]["enet"], ["198.51.100.7", 61000])
        self.assertEqual(self.reg(joined["token"], "enet", ("198.51.100.7", 61000)), [], "same address: no repeat")

    def test_unknown_room_and_garbage(self):
        err = j(self.s.handle(b'{"op":"join","room":"ZZZZZZ"}', ("1.2.3.4", 1), 0))[0][0]
        self.assertEqual(err["op"], "error")
        self.assertEqual(self.s.handle(b"\xff\xfe not json", ("1.2.3.4", 1), 0), [])
        self.assertEqual(self.s.handle(b"ASMR{\"kind\":\"enet\"}", ("1.2.3.4", 1), 0), [])
        self.assertEqual(self.s.handle(b"x" * 5000, ("1.2.3.4", 1), 0), [])

    def test_room_expires_without_keepalive(self):
        self.s.handle(json.dumps({"op": "alive", "room": self.room, "token": self.host_tok}).encode(), self.host_ctl, ROOM_TTL - 1)
        self.s.expire(ROOM_TTL + 0.5)
        self.assertIn(self.room, self.s.rooms)
        self.s.expire(2 * ROOM_TTL)
        self.assertNotIn(self.room, self.s.rooms)

    def test_room_full(self):
        for i in range(5):
            j(self.s.handle(json.dumps({"op": "join", "room": self.room}).encode(), ("10.0.0.%d" % i, 1), 0))
        err = j(self.s.handle(json.dumps({"op": "join", "room": self.room}).encode(), ("10.0.0.99", 1), 0))[0][0]
        self.assertEqual(err["op"], "error")


if __name__ == "__main__":
    unittest.main()
