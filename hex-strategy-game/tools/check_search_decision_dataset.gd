extends SceneTree
## CI parse preflight for the search-decision exporter.
##
## `godot --check-only --script` requires a standalone MainLoop/SceneTree script,
## so preload the Node-based exporter here. Any exporter parse error fails before
## the smoke game starts instead of leaving a scene process alive until job timeout.

const SearchDecisionDataset = preload("res://tools/search_decision_dataset.gd")


func _init() -> void:
	# Referencing the preload keeps static analyzers from treating it as accidental.
	if SearchDecisionDataset == null:
		quit(1)
		return
	print("[search-decisions] exporter parse preflight passed")
	quit(0)
