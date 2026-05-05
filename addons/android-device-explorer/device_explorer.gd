@tool
extends VBoxContainer

const TMP_DIR := "/data/local/tmp"
const STORAGE_ROOT := "/storage/emulated/0"
const PULL_PUSH_TEMP = TMP_DIR + "/godot-device-explorer-plugin"
const ADB_PATH_SETTING = "_android-device-explorer/adb_path"
const PACKAGE_NAME_SETTING = "_android-device-explorer/package_name"

var adb_path: String
var package_name: String
var app_data_dir: String

var topbar: HBoxContainer
var tree: Tree
var devices_btn: OptionButton
var dock_menu_button: MenuButton
var status_label: Label

var current_device: String
var show_all := false
var is_busy := false

enum ContextMenu {
	NEW_FILE,
	NEW_DIRECTORY,
	SAVE_AS,
	UPLOAD,
	DELETE,
	SYNCHRONIZE,
	COPY_PATH
}

enum FileType {
	directory,
	link,
	file
}

class FileInfo:
	var name: String
	var path: String
	var type: FileType
	
	func _init(p_name: String, p_path: String, p_type: FileType) -> void:
		name = p_name
		path = p_path
		type = p_type

class TreeItemMetadata:
	var path: String
	var is_file: bool
	
	func _init(p_path: String, p_is_file: bool) -> void:
		path = p_path
		is_file = p_is_file


func _ready() -> void:
	var saved_adb_path = EditorInterface.get_editor_settings().get_setting(ADB_PATH_SETTING)
	var saved_package_name = EditorInterface.get_editor_settings().get_setting(PACKAGE_NAME_SETTING)
	
	if saved_adb_path != null:
		adb_path = saved_adb_path
	else:
		adb_path = EditorInterface.get_editor_settings().get_setting("export/android/android_sdk_path").path_join("platform-tools/adb")
	
	if saved_package_name != null:
		package_name = saved_package_name
		app_data_dir = "/data/data/"+package_name
	
	if package_name.is_empty() or adb_path.is_empty():
		_show_config_dilaog()
	
	_setup_ui()
	_load_devices()


func _setup_ui() -> void:
	topbar = HBoxContainer.new()
	add_child(topbar)
	
	devices_btn = OptionButton.new()
	devices_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	devices_btn.custom_minimum_size = Vector2(32, 32)
	devices_btn.item_selected.connect(_on_device_selected)
	topbar.add_child(devices_btn)
	
	var reload_btn = Button.new()
	reload_btn.icon = get_theme_icon("Reload", "EditorIcons")
	reload_btn.tooltip_text = "Reload"
	reload_btn.pressed.connect(_load_devices)
	topbar.add_child(reload_btn)
	
	dock_menu_button = MenuButton.new()
	dock_menu_button.icon = get_theme_icon("GuiTabMenuHl", "EditorIcons")
	var popup := dock_menu_button.get_popup()
	popup.add_check_item("Show Full Filesystem", 0)
	popup.set_item_checked(0, show_all)
	popup.add_separator()
	popup.add_icon_item(get_theme_icon("GDScript", "EditorIcons"), "Open Config Window", 1)
	popup.id_pressed.connect(_on_dock_menu_item_pressed)
	topbar.add_child(dock_menu_button)
	
	tree = Tree.new()
	tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	tree.hide_root = true
	tree.allow_rmb_select = true
	tree.item_collapsed.connect(_on_item_collapsed)
	tree.item_mouse_selected.connect(_on_item_mouse_selected)
	add_child(tree)
	
	status_label = Label.new()
	status_label.text = "Ready"
	status_label.add_theme_color_override("font_color", get_theme_color("disabled_font_color", "Editor"))
	add_child(status_label)


func _on_item_mouse_selected(pos: Vector2, mouse_button_index: int) -> void:
	if mouse_button_index == MOUSE_BUTTON_RIGHT:
		_create_context_menu()


func _on_dock_menu_item_pressed(id: int) -> void:
	match id:
		0:
			show_all = !show_all
			dock_menu_button.get_popup().set_item_checked(0, show_all)
			_load_root()
		1:
			_show_config_dilaog()


func _load_devices() -> void:
	var device_list := _get_devices()
	devices_btn.clear()
	
	for i in device_list.size():
		var id = device_list[i]
		var model := _run_adb(["-s", id, "shell", "getprop", "ro.product.model"]).strip_edges()
		var brand := _run_adb(["-s", id, "shell", "getprop", "ro.product.brand"]).strip_edges().capitalize()
		devices_btn.add_item(brand + " " + model, i)
		devices_btn.set_item_metadata(0, id)
	
	if not device_list.is_empty():
		devices_btn.select(0)
		_on_device_selected(0)
	else:
		devices_btn.text = "No Device Found"
		tree.clear()


func _on_device_selected(index: int) -> void:
	current_device = devices_btn.get_item_metadata(index)
	_load_root()


func _load_root() -> void:
	tree.clear()
	if current_device.is_empty():
		return
	
	var root := tree.create_item()
	
	if show_all:
		root.set_text(0, "/")
		root.set_metadata(0, TreeItemMetadata.new("/", false))
		_add_dummy(root)
		_on_dir_expanded(root)
	else:
		root.set_text(0, "Device Scopes")
		_create_tree_item(root, "App Data", app_data_dir, FileType.directory)
		_create_tree_item(root, "Temp Storage", TMP_DIR, FileType.directory)
		_create_tree_item(root, "Internal Storage", STORAGE_ROOT, FileType.directory)
	
	_run_adb(["shell", "mkdir", PULL_PUSH_TEMP])


func _create_tree_item(parent: TreeItem, text: String, path: String, type: FileType, custom_icon := "", skip_dummy := false) -> TreeItem:
	var item := tree.create_item(parent)
	item.set_text(0, text)
	item.set_metadata(0, TreeItemMetadata.new(path, type == FileType.file))
	
	var icon_name = custom_icon if not custom_icon.is_empty() else _get_icon_for_ext(path)
	
	if type == FileType.directory:
		if custom_icon.is_empty(): icon_name = "Folder"
		item.set_icon_modulate(0, get_theme_color("accent_color", "Editor"))
		if not skip_dummy: _add_dummy(item)
	elif type == FileType.link:
		if custom_icon.is_empty(): icon_name = "ExternalLink"
		if not skip_dummy: _add_dummy(item)
	
	item.set_icon(0, get_theme_icon(icon_name, "EditorIcons"))
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
	var meta: TreeItemMetadata = item.get_metadata(0)
	if not meta or meta.is_file: return
	
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
	
	var files: Array[FileInfo] = _list_dir(path)
	if files.size() > 0 or refresh:
		# Files are loaded, now remove the dummy file or old items.
		for child in item.get_children():
			child.free()
	
	if files.is_empty() and refresh:
		_add_dummy.call_deferred(item)
	
	for f in files:
		_create_tree_item.call_deferred(item, f.name, f.path, f.type)


func _populate_special_data_dir(parent: TreeItem) -> void:
	var data_node = _create_tree_item(parent, "data", "/data/data", FileType.directory, "", true)
	var local_node = _create_tree_item(parent, "local", "/data/local", FileType.directory, "", true)
	var tmp_node = _create_tree_item(local_node, "tmp", TMP_DIR, FileType.directory)
	var pkg_node = _create_tree_item(data_node, package_name, app_data_dir, FileType.directory)


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
			file_dialog.file_selected.connect(_pull_file.bind(remote_path))
	
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


func _show_create_dialog(remote_path: String, creating_dir: bool) -> void:
	var dialog = ConfirmationDialog.new()
	var input := LineEdit.new()
	if creating_dir:
		dialog.title = "Enter a new folder name"
		input.text = "MyFolder"
	else:
		dialog.title = "Enter a new file name"
		input.text = "MyFile.txt"
	input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	dialog.add_child(input)
	
	input.text_changed.connect(func (new_text: String): dialog.get_ok_button().disabled = new_text.is_empty())
	
	dialog.confirmed.connect(_create_file_or_directory.bind(remote_path.path_join(input.text), creating_dir))
	add_child(dialog)
	dialog.popup_centered(Vector2i(350, 100))
	dialog.visibility_changed.connect(_dialog_visibility_changed.bind(dialog))


func _show_config_dilaog() -> void:
	var dialog = ConfirmationDialog.new()
	dialog.title = "Device Explorer Configuration"
	dialog.ok_button_text = "Save"
	dialog.exclusive = false
	var vbox := VBoxContainer.new()
	vbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	dialog.add_child(vbox)
	
	var adb_label := Label.new()
	adb_label.text = "ADB Path:"
	vbox.add_child(adb_label)
	var adb_input := LineEdit.new()
	adb_input.placeholder_text = "Enter ADB executable path..."
	adb_input.text = adb_path
	adb_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_child(adb_input)
	
	var package_label := Label.new()
	package_label.text = "Package Name:"
	vbox.add_child(package_label)
	var pkg_input := LineEdit.new()
	pkg_input.placeholder_text = "Enter app package name..."
	pkg_input.text = package_name
	pkg_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_child(pkg_input)
	
	dialog.confirmed.connect(func():
		adb_path = adb_input.text
		package_name = pkg_input.text
		app_data_dir = "/data/data/"+package_name
		EditorInterface.get_editor_settings().set_setting(ADB_PATH_SETTING, adb_path)
		EditorInterface.get_editor_settings().set_setting(PACKAGE_NAME_SETTING, package_name)
	)
	add_child(dialog)
	dialog.popup_centered(Vector2i(400, 180))
	dialog.visibility_changed.connect(_dialog_visibility_changed.bind(dialog))


func _dialog_visibility_changed(dialog: Window) -> void:
	if not dialog.visible:
		dialog.queue_free()


# ADB Handling--------------------------------------------------------------------------------------

func _execute_threaded(callable: Callable, status_msg: String) -> void:
	if is_busy: return
	_update_status(status_msg, true)
	
	WorkerThreadPool.add_task(func():
		callable.call()
		call_deferred("_update_status", "Ready", false)
	)


func _update_status(msg: String, busy: bool) -> void:
	is_busy = busy
	status_label.text = msg
	process_mode = Node.PROCESS_MODE_DISABLED if busy else Node.PROCESS_MODE_INHERIT
	
	var busy_color = get_theme_color("warning_color", "Editor")
	var idle_color = get_theme_color("disabled_font_color", "Editor")
	var modulate_color = Color(1, 1, 1, 0.5) if busy else Color(1, 1, 1, 1)
	tree.modulate = modulate_color
	topbar.modulate = modulate_color
	status_label.add_theme_color_override("font_color", busy_color if busy else idle_color)


func _run_adb(p_args: PackedStringArray) -> String:
	var args: PackedStringArray = []
	if not current_device.is_empty():
		args.append_array(["-s", current_device])
	args.append_array(p_args)
	
	var output := []
	OS.execute(adb_path, args, output, true)
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


func _list_dir(path: String) -> Array[FileInfo]:
	var args := ["shell"]
	var ls_cmd = "ls -1 -F '%s'" % path
	if path.begins_with(app_data_dir):
		args.append_array(["run-as", package_name, ls_cmd])
	else:
		args.append(ls_cmd)
	
	var result := _run_adb(args)
	var files: Array[FileInfo]
	for line in result.split("\n"):
		line = line.strip_edges()
		if line == "" or line.begins_with("total"): continue
		
		var file_info = FileInfo.new(line, path.path_join(line), FileType.file)
		
		if line.ends_with("@"):
			file_info.name = line.rstrip("@")
			file_info.type = FileType.link
			file_info.path = _resolve_link(path.path_join(file_info.name))
		elif line.ends_with("/"):
			file_info.name = line.rstrip("/")
			file_info.type = FileType.directory
		
		files.append(file_info)
	return files

func _resolve_link(full_path: String) -> String:
	var result = _run_adb(["shell", "readlink -f '%s'" % full_path])
	return result.strip_edges()


func _pull_file(local_path: String, remote_path: String) -> void:
	_execute_threaded(func():
		_pull_file_internal(local_path, remote_path)
	, "Pulling: " + remote_path.get_file())


func _pull_dir(local_path: String, remote_path: String) -> void:
	_execute_threaded(func():
		_pull_dir_internal(local_path, remote_path)
	, "Pulling Directory: " + remote_path.get_file())


func _pull_dir_internal(local_path: String, remote_path: String) -> void:
	if not remote_path.begins_with(app_data_dir):
		_run_adb(["pull", remote_path, local_path])
		return
	
	# special handling for app's private data dir
	var ls_cmd = "ls -1 -F '%s'" % remote_path
	var output = _run_adb(["shell", "run-as", package_name, ls_cmd])
	
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
			_pull_file_internal(item_local_path, item_remote_path)


func _pull_file_internal(local_path: String, remote_path: String) -> void:
	if not remote_path.begins_with(app_data_dir):
		_run_adb(["pull", remote_path, local_path])
		return
	
	# special handling for app's private data dir
	var temp_name = "temp_" + str(Time.get_ticks_usec())
	var temp_path = PULL_PUSH_TEMP.path_join(temp_name)
	
	_run_adb(["shell", "touch", temp_path])
	var cp_cmd = "cp '%s' '%s'" % [remote_path, temp_path]
	_run_adb(["shell", "run-as", package_name, cp_cmd])
	_run_adb(["pull", temp_path, local_path])
	_run_adb(["shell", "rm", temp_path])


func _push(local_path: String, remote_path: String) -> void:
	_execute_threaded(func():
		if not remote_path.begins_with(app_data_dir):
			_run_adb(["push", local_path, remote_path])
		else:
			var temp_name = "temp_" + str(Time.get_ticks_usec())
			var temp_path = PULL_PUSH_TEMP.path_join(temp_name)
			_run_adb(["push", local_path, temp_path])
			var exact_remote_path = remote_path.path_join(local_path.get_file())
			var cp_cmd = "cp -r '%s' '%s'" % [temp_path, exact_remote_path]
			_run_adb(["shell", "run-as", package_name, cp_cmd])
			_run_adb(["shell", "rm", "-rf", temp_path])
		
		call_deferred("_on_dir_expanded", tree.get_selected(), true)
	, "Uploading: " + local_path.get_file())


func _delete(remote_path: String) -> void:
	_execute_threaded(func():
		var delete_cmd = "rm -r '%s'" % remote_path
		if remote_path.begins_with(app_data_dir):
			_run_adb(["shell", "run-as", package_name, delete_cmd])
		else:
			_run_adb(["shell", delete_cmd])
		call_deferred("_on_dir_expanded", tree.get_selected().get_parent(), true)
	, "Deleting: " + remote_path.get_file())


func _create_file_or_directory(path: String, creating_dir: bool) -> void:
	var cmd: String
	if creating_dir:
		cmd = "mkdir '%s'" % path
	else:
		cmd = "touch '%s'" % path
	
	if path.begins_with(app_data_dir):
		_run_adb(["shell", "run-as", package_name, cmd])
	else:
		_run_adb(["shell", cmd])
	
	# Finally refresh the tree view
	_on_dir_expanded(tree.get_selected(), true)

#---------------------------------------------------------------------------------------------------

func _get_icon_for_ext(path: String) -> String:
	var ext := path.get_extension().to_lower()
	match ext:
		"gd": return "GDScript"
		"tscn": return "PackedScene"
		"png", "jpg", "svg": return "ImageTexture"
		"txt", "json": return "TextFile"
		_: return "File"


func _create_context_menu() -> void:
	var item = tree.get_selected()
	if not item: return
	
	var menu = PopupMenu.new()
	
	var is_dir = not item.get_metadata(0).is_file
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
	var meta: TreeItemMetadata = item.get_metadata(0) if item else null
	if not meta: return
	
	match id:
		ContextMenu.NEW_FILE:
			_show_create_dialog(meta.path, false)
		ContextMenu.NEW_DIRECTORY:
			_show_create_dialog(meta.path, true)
		ContextMenu.SAVE_AS:
			_show_file_dialog(meta.path, false, not meta.is_file)
		ContextMenu.UPLOAD:
			_show_file_dialog(meta.path, true)
		ContextMenu.DELETE:
			_show_delete_dialog(meta.path, not meta.is_file)
		ContextMenu.SYNCHRONIZE:
			_on_dir_expanded(item, true)
		ContextMenu.COPY_PATH:
			DisplayServer.clipboard_set(meta.path)
