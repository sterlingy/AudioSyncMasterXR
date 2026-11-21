extends SceneTree
## Two-instance session test on this machine. Run:
##   godot --headless --path . -s res://tests/tools/net_test.gd
## It hosts, starts a second Godot process that joins as a client, and checks
## clock sync, tempo following, live notes over direct UDP, sound/sequencer
## sync, master-looper sharing and host-approved tempo changes.
## Exit code 0 = pass. The host runs its clock 3.217 s ahead to prove sync.



func _initialize() -> void:
	_start.call_deferred()


func _start() -> void:
	var body: Node = load("res://tests/tools/net_test_body.gd").new()
	body.name = "NetTest"
	root.add_child(body)
