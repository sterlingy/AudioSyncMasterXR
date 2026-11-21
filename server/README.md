# Connection server

Lets players on different networks find each other. The host gets a 6-letter
room code; others type it in the Jam tab (**Join online**). The server only
introduces players and helps open direct paths through home routers (UDP hole
punching). Audio, notes and session data still go player to player.

## Run it

Needs Python 3.8+ (standard library only) and one open UDP port.

```
python3 asm_server.py --port 47900
```

On a cloud VM, allow inbound UDP 47900 in its firewall / security group. To keep
it running, a systemd unit like this works:

```
[Unit]
Description=AudioSyncMaster connection server
After=network.target

[Service]
ExecStart=/usr/bin/python3 /opt/asm/asm_server.py --port 47900
Restart=always
DynamicUser=yes

[Install]
WantedBy=multi-user.target
```

In the app: Jam tab → **Online** → type the server's address (`host` or
`host:port`), then **Host online** or a room code + **Join online**.

## How it works

1. The host asks for a room and gets a code and a token.
2. Each of a player's UDP sockets (session/ENet, clock, audio) sends a small
   `ASMR` + JSON registration packet; the server records the public address it
   came from.
3. A joiner asks for the host's public addresses and connects straight to them.
   When the joiner's sockets register, the server tells the host, which sends a
   few packets toward them so its own router lets the joiner in.
4. Players share their public audio address in the session, so audio streams go
   directly between every pair (their HELLO packets keep the paths open).

Rooms expire 60 s after the host stops sending keepalives. Up to 6 players per
room.

## Limits

- Works with most home routers (endpoint-independent mapping). Strict NATs
  (some mobile carriers, corporate networks) need a relay, which isn't built yet.
- No accounts or passwords: anyone with the code can join while the room is open.

Tests: `python -m unittest test_asm_server` (room logic), and the full flow:
run the server locally, then
`godot --headless --path . -s res://tests/tools/net_test.gd -- --server=127.0.0.1:47900`.
