extends Node
## RPC side channel for tests/tools/net_test.gd (same node path in both processes).

signal reported(data: Dictionary)
signal finished


@rpc("any_peer", "reliable")
func report(data: Dictionary) -> void:
	reported.emit(data)


@rpc("authority", "reliable")
func finish() -> void:
	finished.emit()
