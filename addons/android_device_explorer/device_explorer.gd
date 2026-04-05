@tool
extends VBoxContainer

const ADB_PATH := "/home/anish/Android/Sdk/platform-tools/adb"
const PACKAGE_NAME := "org.godotengine.editor.v4.debug"
const DATA_ROOT := "/data/data/" + PACKAGE_NAME
const TMP_DIR := "/data/local/tmp"
const STORAGE_ROOT := "/storage/emulated/0"
const PULL_PUSH_TEMP = TMP_DIR + "/godot-device-explorer-plugin"

@onready var tree: Tree = $Tree
@onready var devices_btn: OptionButton = $HBoxContainer/OptionButton
@onready var menu_button: MenuButton = $HBoxContainer/MenuButton

var current_device := ""
var show_all := false


func _ready() -> void:
	_setup_ui()
	_load_devices()


func _setup_ui() -> void:
	tree.hide_root = true
	tree.item_collapsed.connect(_on_item_collapsed)
	
	devices_btn.custom_minimum_size = Vector2(32, 32)
	devices_btn.selected = -1
	devices_btn.pressed.connect(_load_devices)
	devices_btn.item_selected.connect(_on_device_selected)
	
	menu_button.icon = EditorInterface.get_base_control().get_theme_icon("GuiTabMenuHl", "EditorIcons")
	var popup := menu_button.get_popup()
	popup.clear()
	popup.add_check_item("Show Full Filesystem", 0)
	popup.set_item_checked(0, show_all)
	popup.id_pressed.connect(_on_menu_item_pressed)


func _load_devices() -> void:
	var device_list := _get_devices()
	var selected = devices_btn.get_selected_id()
	devices_btn.clear()
	
	for d in device_list:
		devices_btn.add_item(d)
	
	if device_list.size() > 0:
		if selected != -1:
			devices_btn.select(selected)
		else:
			devices_btn.select(0)
			_on_device_selected(0)
	else:
		devices_btn.text = "No Device Found"
		tree.clear()


func _on_device_selected(index: int) -> void:
	current_device = devices_btn.get_item_text(index)
	_load_root()


func _load_root() -> void:
	tree.clear()
	var root := tree.create_item()
	
	if show_all:
		root.set_text(0, "/")
		root.set_metadata(0, {"path": "/", "is_dir": true})
		_add_dummy(root)
		_on_dir_expanded(root)
	else:
		root.set_text(0, "Device Scopes")
		_create_tree_item(root, "App Data", DATA_ROOT, true)
		_create_tree_item(root, "Temp Storage", TMP_DIR, true)
		_create_tree_item(root, "Internal Storage", STORAGE_ROOT, true)
	
	_run_adb(["shell", "mkdir", PULL_PUSH_TEMP])


func _create_tree_item(parent: TreeItem, text: String, path: String, is_dir: bool, custom_icon := "", skip_dummy := false) -> TreeItem:
	var item := tree.create_item(parent)
	item.set_text(0, text)
	item.set_metadata(0, {"path": path, "is_dir": is_dir})
	
	var gui := EditorInterface.get_base_control()
	var icon_name = custom_icon if custom_icon != "" else ("Folder" if is_dir else _get_icon_for_ext(path))
	item.set_icon(0, gui.get_theme_icon(icon_name, "EditorIcons"))
	
	if is_dir:
		item.set_icon_modulate(0, gui.get_theme_color("accent_color", "Editor"))
		if not skip_dummy: _add_dummy(item)
	
	item.collapsed = true
	return item


func _add_dummy(parent: TreeItem) -> void:
	var dummy := tree.create_item(parent)
	dummy.set_text(0, "Empty...")
	dummy.set_metadata(0, null)


func _on_item_collapsed(item: TreeItem) -> void:
	if not item.collapsed:
		_on_dir_expanded(item)


func _on_dir_expanded(item: TreeItem, refresh := false) -> void:
	var meta = item.get_metadata(0)
	if not meta or not meta.is_dir: return
	
	# Skip if already loaded (and not refreshing)
	if item.get_child_count() > 0 && not refresh:
		var first_child := item.get_child(0)
		if first_child.get_text(0) != "Empty...":
			return
	
	var path: String = meta.path
	
	# Direct access to /data is restricted by system permissions.
	# Manually constructing a sub-directory tree to allow navigation into accessible paths (example, app userdata or tmp).
	if path == "/data":
		var first_child := item.get_child(0)
		first_child.free() # remove the dummy file for it.
		_populate_special_data_dir.call_deferred(item)
		return
	
	var files: Array = _list_dir(path)
	if files.size() > 0:
		# Files are loaded, now remove the dummy file or old items.
		for child in item.get_children():
			child.free()
	
	for f in files:
		var full_path = path.rstrip("/") + "/" + f.name
		_create_tree_item.call_deferred(item, f.name, full_path, f.is_dir)


func _populate_special_data_dir(parent: TreeItem) -> void:
	var data_node = _create_tree_item(parent, "data", "/data/data", true, "", true)
	var local_node = _create_tree_item(parent, "local", "/data/local", true, "", true)
	var tmp_node = _create_tree_item(local_node, "tmp", TMP_DIR, true)
	var pkg_node = _create_tree_item(data_node, PACKAGE_NAME, DATA_ROOT, true)


func _on_menu_item_pressed(id: int) -> void:
	if id == 0:
		show_all = !show_all
		menu_button.get_popup().set_item_checked(0, show_all)
		_load_root()


func _run_adb(p_args: PackedStringArray) -> String:
	var args: PackedStringArray = []
	if current_device != "":
		args.append_array(["-s", current_device])
	args.append_array(p_args)
	
	var output := []
	OS.execute(ADB_PATH, args, output, true)
	return output[0] if output.size() > 0 else ""


func _get_devices() -> Array[String]:
	var raw := _run_adb(["devices"])
	var lines := raw.split("\n")
	var result: Array[String] = []
	for i in range(1, lines.size()):
		var parts := lines[i].strip_edges().split("\t")
		if parts.size() >= 2 and parts[1] == "device":
			result.append(parts[0])
	return result


func _list_dir(path: String) -> Array:
	var args := ["shell"]
	var ls_cmd = "ls -1 -F '%s'" % path
	if path.begins_with(DATA_ROOT):
		args.append_array(["run-as", PACKAGE_NAME, ls_cmd])
	else:
		args.append(ls_cmd)
	
	var result := _run_adb(args)
	var files := []
	for line in result.split("\n"):
		line = line.strip_edges()
		if line.ends_with("@"): continue # Ignore links like /sdcard for now. I'll handle it later.
		if line == "" or line.begins_with("total"): continue
		files.append({"name": line.rstrip("/"), "is_dir": line.ends_with("/")})
	return files


func _get_icon_for_ext(path: String) -> String:
	var ext := path.get_extension().to_lower()
	match ext:
		"gd": return "GDScript"
		"tscn": return "PackedScene"
		"res", "tres": return "Resource"
		"png", "jpg", "svg": return "ImageTexture"
		"txt", "json": return "TextFile"
		_: return "File"
	
