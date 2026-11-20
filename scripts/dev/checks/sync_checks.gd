extends RefCounted
## Self-test checks for this area. `t` is the self-test node: call t.check(name, got, want).


func run(t: Node) -> void:
	await t.get_tree().process_frame
