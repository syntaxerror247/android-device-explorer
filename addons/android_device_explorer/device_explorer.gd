@tool
extends VBoxContainer

const ADB_PATH := "/home/anish/Android/Sdk/platform-tools/adb"
const PACKAGE_NAME := "org.godotengine.editor.v4.debug"
const DATA_ROOT := "/data/data/" + PACKAGE_NAME
const TMP_DIR := "/data/local/tmp"
const STORAGE_ROOT := "/storage/emulated/0"
const PULL_PUSH_TEMP = TMP_DIR + "/godot-device-explorer-plugin"

var tree: Tree
var devices_btn: OptionButton
var menu_button: MenuButton

var current_device := ""
var show_all := false

enum ContextMenu {
	NEW_FILE,
	NEW_DIRECTORY,
	SAVE_AS,
	UPLOAD,
	DELETE,
	SYNCHRONIZE,
	COPY_PATH
}

func _ready() -> void:
	_setup_ui()
	_load_devices()


func _setup_ui() -> void:
	var hbox := HBoxContainer.new()
	add_child(hbox)
	
	devices_btn = OptionButton.new()
	devices_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	devices_btn.custom_minimum_size = Vector2(32, 32)
	devices_btn.pressed.connect(_load_devices)
	devices_btn.item_selected.connect(_on_device_selected)
	hbox.add_child(devices_btn)
	
	var reload_btn = Button.new()
	reload_btn.icon = get_theme_icon("Reload", "EditorIcons")
	reload_btn.pressed.connect(_load_root)
	hbox.add_child(reload_btn)
	
	menu_button = MenuButton.new()
	menu_button.icon = get_theme_icon("GuiTabMenuHl", "EditorIcons")
	var popup := menu_button.get_popup()
	popup.add_check_item("Show Full Filesystem", 0)
	popup.set_item_checked(0, show_all)
	popup.id_pressed.connect(_on_menu_item_pressed)
	hbox.add_child(menu_button)
	
	tree = Tree.new()
	tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	tree.hide_root = true
	tree.allow_rmb_select = true
	tree.item_collapsed.connect(_on_item_collapsed)
	tree.item_mouse_selected.connect(_on_item_mouse_selected)
	add_child(tree)


func _on_item_mouse_selected(pos: Vector2, mouse_button_index: int) -> void:
	if mouse_button_index == MOUSE_BUTTON_RIGHT:
		create_context_menu()


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
	
	var icon_name = custom_icon if custom_icon != "" else ("Folder" if is_dir else _get_icon_for_ext(path))
	item.set_icon(0, get_theme_icon(icon_name, "EditorIcons"))
	
	if is_dir:
		item.set_icon_modulate(0, get_theme_color("accent_color", "Editor"))
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
	if files.size() > 0 or refresh:
		# Files are loaded, now remove the dummy file or old items.
		for child in item.get_children():
			child.free()
	
	if files.is_empty() and refresh:
		_add_dummy.call_deferred(item)
	
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


func _show_file_dialog(remote_path: String, is_uploading: bool, is_dir: bool = false) -> void:
	var file_dialog = EditorFileDialog.new()
	file_dialog.access = FileDialog.ACCESS_FILESYSTEM
	
	if is_uploading:
		file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_ANY
		file_dialog.title = "Select file or directory to upload"
		file_dialog.file_selected.connect(_push.bind(remote_path))
		file_dialog.dir_selected.connect(_push.bind(remote_path))
	else:
		if is_dir:
			file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
			file_dialog.title = "Save directory to..."
			file_dialog.dir_selected.connect(_pull_dir.bind(remote_path))
		else:
			file_dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
			file_dialog.title = "Save file as..."
			file_dialog.current_file = remote_path.get_file()
			file_dialog.file_selected.connect(_pull_single_file.bind(remote_path))
	
	add_child(file_dialog)
	file_dialog.popup_file_dialog()
	file_dialog.visibility_changed.connect(_dialog_visibility_changed.bind(file_dialog))


func _show_delete_dialog(remote_path: String, is_dir: bool) -> void:
	var confirm_dialog = ConfirmationDialog.new()
	confirm_dialog.title = "Delete"
	confirm_dialog.dialog_text = "Are you sure you want to delete %s '%s'?" % ["folder" if is_dir else "file", remote_path.get_file()]
	confirm_dialog.confirmed.connect(_delete.bind(remote_path))
	add_child(confirm_dialog)
	confirm_dialog.popup_centered()
	confirm_dialog.visibility_changed.connect(_dialog_visibility_changed.bind(confirm_dialog))


func _dialog_visibility_changed(dialog: AcceptDialog) -> void:
	if not dialog.visible:
		dialog.queue_free()

# ADB Handling--------------------------------------------------------------------------------------

func _run_adb(p_args: PackedStringArray) -> String:
	var args: PackedStringArray = []
	if current_device != "":
		args.append_array(["-s", current_device])
	args.append_array(p_args)
	
	var output := []
	OS.execute(ADB_PATH, args, output, true)
	#print(output)
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


func _pull_dir(local_path: String, remote_path: String) -> void:
	if not remote_path.begins_with(DATA_ROOT):
		_run_adb(["pull", remote_path, local_path])
		return
	
	# special handling for app's private data dir
	var ls_cmd = "ls -1 -F '%s'" % remote_path
	var output = _run_adb(["shell", "run-as", PACKAGE_NAME, ls_cmd])
	
	local_path = local_path.path_join(remote_path.get_file()) # Create the base directory in local path
	if not DirAccess.dir_exists_absolute(local_path):
		DirAccess.make_dir_recursive_absolute(local_path)
	
	for line in output.split("\n"):
		line = line.strip_edges()
		if line == "" or line.begins_with("total"): continue
		
		var is_dir = line.ends_with("/")
		var item_name = line.trim_suffix("/")
		var item_remote_path = remote_path.path_join(item_name)
		var item_local_path = local_path.path_join(item_name)
		
		if is_dir:
			_pull_dir(item_local_path, item_remote_path)
		else:
			_pull_single_file(item_local_path, item_remote_path)


func _pull_single_file(local_path: String, remote_path: String) -> void:
	if not remote_path.begins_with(DATA_ROOT):
		_run_adb(["pull", remote_path, local_path])
		return
	
	# special handling for app's private data dir
	var temp_name = "temp_" + str(Time.get_ticks_usec())
	var temp_path = PULL_PUSH_TEMP.path_join(temp_name)
	
	_run_adb(["shell", "touch", temp_path])
	var cp_cmd = "cp '%s' '%s'" % [remote_path, temp_path]
	_run_adb(["shell", "run-as", PACKAGE_NAME, cp_cmd])
	_run_adb(["pull", temp_path, local_path])
	_run_adb(["shell", "rm", temp_path])


func _push(local_path: String, remote_path: String) -> void:
	if not remote_path.begins_with(DATA_ROOT):
		_run_adb(["push", local_path, remote_path])
		return
	
	# special handling for app's private data dir
	var temp_name = "temp_" + str(Time.get_ticks_usec())
	var temp_path = PULL_PUSH_TEMP.path_join(temp_name)
	
	_run_adb(["push", local_path, temp_path])
	
	var source_name = local_path.get_file()
	var exact_remote_path = remote_path.path_join(source_name)
	
	var cp_cmd = "cp -r '%s' '%s'" % [temp_path, exact_remote_path]
	_run_adb(["shell", "run-as", PACKAGE_NAME, cp_cmd])
	_run_adb(["shell", "rm", "-rf", temp_path])
	
	# Finally refresh the tree view to show newly uploaded file
	_on_dir_expanded(tree.get_selected(), true)


func _delete(remote_path: String) -> void:
	var delete_cmd = "rm -r '%s'" % remote_path
	if remote_path.begins_with(DATA_ROOT):
		var a = _run_adb(["shell", "run-as", PACKAGE_NAME, delete_cmd])
		print(a)
	else:
		_run_adb(["shell", delete_cmd])
	
	# Finally refresh the tree view
	_on_dir_expanded(tree.get_selected().get_parent(), true)

#---------------------------------------------------------------------------------------------------

func _get_icon_for_ext(path: String) -> String:
	var ext := path.get_extension().to_lower()
	match ext:
		"gd": return "GDScript"
		"tscn": return "PackedScene"
		"png", "jpg", "svg": return "ImageTexture"
		"txt", "json": return "TextFile"
		_: return "File"


func create_context_menu() -> void:
	var item = tree.get_selected()
	if not item: return
	
	var menu = PopupMenu.new()
	
	var is_dir = item.get_metadata(0).is_dir
	if is_dir:
		var sub_menu = PopupMenu.new()
		sub_menu.add_icon_item(get_theme_icon("File", "EditorIcons"), "File", ContextMenu.NEW_FILE)
		sub_menu.add_icon_item(get_theme_icon("Folder", "EditorIcons"), "Directory", ContextMenu.NEW_DIRECTORY)
		sub_menu.id_pressed.connect(_on_context_menu_item_pressed)
		menu.add_submenu_node_item("New", sub_menu)
		menu.add_separator()
	
	menu.add_icon_item(get_theme_icon("MoveDown", "EditorIcons"), "Save As", ContextMenu.SAVE_AS)
	if is_dir:
		menu.add_icon_item(get_theme_icon("MoveUp", "EditorIcons"), "Upload", ContextMenu.UPLOAD)
	menu.add_icon_item(get_theme_icon("Remove", "EditorIcons"), "Delete", ContextMenu.DELETE)
	menu.add_separator()
	menu.add_icon_item(get_theme_icon("Reload", "EditorIcons"), "Synchronize", ContextMenu.SYNCHRONIZE)
	menu.add_icon_item(get_theme_icon("ActionCopy", "EditorIcons"), "Copy Path", ContextMenu.COPY_PATH)
	
	menu.id_pressed.connect(_on_context_menu_item_pressed)
	menu.popup_hide.connect(menu.queue_free)
	add_child(menu)
	
	menu.position = DisplayServer.mouse_get_position()
	menu.popup()


func _on_context_menu_item_pressed(id: int) -> void:
	var item = tree.get_selected()
	var meta = item.get_metadata(0) if item else null
	if not meta: return
	
	match id:
		ContextMenu.SAVE_AS:
			_show_file_dialog(meta.path, false, meta.is_dir)
		ContextMenu.UPLOAD:
			_show_file_dialog(meta.path, true)
		ContextMenu.DELETE:
			_show_delete_dialog(meta.path, meta.is_dir)
		ContextMenu.SYNCHRONIZE:
			_on_dir_expanded(item, true)
		ContextMenu.COPY_PATH:
			DisplayServer.clipboard_set(meta.path)
	
