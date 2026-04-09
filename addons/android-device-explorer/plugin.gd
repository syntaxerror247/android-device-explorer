@tool
extends EditorPlugin

var dock

func _enter_tree():
	var dock_control = preload("res://addons/android-device-explorer/device_explorer.gd").new()
	dock = EditorDock.new()
	dock.add_child(dock_control)
	dock.title = "Device Explorer"
	dock.default_slot = EditorDock.DOCK_SLOT_RIGHT_BL
	dock.available_layouts = EditorDock.DOCK_LAYOUT_VERTICAL | EditorDock.DOCK_LAYOUT_FLOATING
	dock.dock_icon = load("res://addons/android-device-explorer/device_explorer_icon.svg")
	add_dock(dock)

func _exit_tree():
	remove_dock(dock)
	dock.queue_free()
