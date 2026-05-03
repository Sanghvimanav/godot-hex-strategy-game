extends PanelContainer

@onready var list: VBoxContainer = $list

func _ready() -> void:
	_build_list()

func _build_list() -> void:
	if not list:
		return
	for child in list.get_children():
		child.queue_free()
	var title := Label.new()
	title.text = "Action Order"
	title.theme_type_variation = "UiFormLabel"
	list.add_child(title)
	for i in Actions.ACTION_ORDER.size():
		var action_type: String = Actions.ACTION_ORDER[i]
		var label := Label.new()
		label.text = "%d. %s" % [i + 1, action_type.capitalize()]
		label.theme_type_variation = "UiHint"
		list.add_child(label)
