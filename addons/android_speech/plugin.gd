@tool
extends EditorPlugin
## Android export additions for text-to-speech:
## - The BibliothecaVivaSpeech plugin (java/): reads aloud with Android's TextToSpeech behind a
##   media notification, so reading continues while the app is in the background, where
##   Godot's main loop is stopped. Its sources are copied into the Gradle build template.
## - A <queries> entry for TTS_SERVICE. Since Android 11 an app only sees the TTS engines of
##   other apps (RHVoice, eSpeak, …) when its manifest declares it; otherwise TextToSpeech
##   silently falls back to a system engine such as Google TTS.
## Both need a Gradle build, which is the only kind where Godot adds manifest entries.

var _export: ExportPlugin


func _enter_tree() -> void:
	_export = ExportPlugin.new()
	add_export_plugin(_export)


func _exit_tree() -> void:
	remove_export_plugin(_export)
	_export = null


class ExportPlugin extends EditorExportPlugin:
	const SOURCES := "res://addons/android_speech/java"
	const TARGET := "res://android/build/src/main/java/com/alsderda/bibliotheca_viva/speech"
	const PACKAGE := "com.alsderda.bibliotheca_viva.speech"

	func _get_name() -> String:
		return "AndroidSpeech"

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

	func _get_android_manifest_element_contents(_platform: EditorExportPlatform, _debug: bool) -> String:
		return """    <uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK" />
    <queries>
        <intent>
            <action android:name="android.intent.action.TTS_SERVICE" />
        </intent>
    </queries>"""

	func _get_android_manifest_application_element_contents(_platform: EditorExportPlatform, _debug: bool) -> String:
		return """        <service
            android:name="%s.SpeechService"
            android:exported="false"
            android:foregroundServiceType="mediaPlayback" />
        <meta-data
            android:name="org.godotengine.plugin.v2.BibliothecaVivaSpeech"
            android:value="%s.SpeechPlugin" />""" % [PACKAGE, PACKAGE]
