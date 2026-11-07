@tool
extends EditorPlugin
## Android export addition: the BibliothecaVivaShare plugin (java/), which opens Android's
## share menu for a file in the app's own storage (used for Settings → About → Troubleshooting
## → Share). It hands the file over through the FileProvider that Godot's Android library
## already declares (authority <package>.fileprovider, covering the app's files folder), so
## no manifest entries besides the plugin itself are needed. Its sources are copied into the
## Gradle build template, like addons/android_speech.

var _export: ExportPlugin


func _enter_tree() -> void:
	_export = ExportPlugin.new()
	add_export_plugin(_export)


func _exit_tree() -> void:
	remove_export_plugin(_export)
	_export = null


class ExportPlugin extends EditorExportPlugin:
	const SOURCES := "res://addons/android_share/java"
	const TARGET := "res://android/build/src/main/java/com/alsderda/bibliotheca_viva/share"
	const PACKAGE := "com.alsderda.bibliotheca_viva.share"

	func _get_name() -> String:
		return "AndroidShare"

	func _supports_platform(platform: EditorExportPlatform) -> bool:
		return platform is EditorExportPlatformAndroid

	func _export_begin(features: PackedStringArray, _is_debug: bool, _path: String, _flags: int) -> void:
		if not features.has("android"):
			return
		var target := ProjectSettings.globalize_path(TARGET)
		if DirAccess.dir_exists_absolute(target):
			for f in DirAccess.get_files_at(target):
				DirAccess.remove_absolute(target.path_join(f))
		DirAccess.make_dir_recursive_absolute(target)
		for f in DirAccess.get_files_at(SOURCES):
			if f.ends_with(".java"):
				DirAccess.copy_absolute(ProjectSettings.globalize_path(SOURCES.path_join(f)), target.path_join(f))

	func _get_android_manifest_application_element_contents(_platform: EditorExportPlatform, _debug: bool) -> String:
		return """        <meta-data
            android:name="org.godotengine.plugin.v2.BibliothecaVivaShare"
            android:value="%s.SharePlugin" />""" % PACKAGE
