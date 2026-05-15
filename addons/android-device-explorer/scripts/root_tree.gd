@tool
extends Tree

func _init() -> void:
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	hide_root = true
	allow_rmb_select = true


func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:
	return data is Dictionary and data.has("files")

func _drop_data(at_position: Vector2, data: Variant) -> void:
	var dropped_files = data["files"]
	var target_item = get_item_at_position(at_position)
	var path: String = target_item.get_metadata(0).path
	if not path or path.is_empty(): return
	
	for file_path in dropped_files:
		get_parent()._push(ProjectSettings.globalize_path(file_path), path.path_join(file_path.get_file()))
		get_parent()._on_dir_expanded(target_item, true)
