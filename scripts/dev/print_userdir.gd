extends SceneTree
## Prints the user data folder (used by synctest.sh).

func _init() -> void:
	print(ProjectSettings.globalize_path("user://"))
	quit()
