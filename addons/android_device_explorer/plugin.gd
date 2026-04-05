@tool
extends EditorPlugin

var dock

func _enter_tree():
	var dock_scene = preload("res://addons/android_device_explorer/device_explorer.tscn").instantiate()
	
	dock = EditorDock.new()
	dock.add_child(dock_scene)
	dock.title = "Android Device Explorer"
	dock.default_slot = EditorDock.DOCK_SLOT_RIGHT_BL
	dock.available_layouts = EditorDock.DOCK_LAYOUT_VERTICAL | EditorDock.DOCK_LAYOUT_FLOATING
	add_dock(dock)

func _exit_tree():
	remove_dock(dock)
	dock.queue_free()
