package com.alsderda.bibliotheca_viva.share;

import android.app.Activity;
import android.content.ClipData;
import android.content.Intent;
import android.net.Uri;
import android.util.Log;

import androidx.core.content.FileProvider;

import java.io.File;

import org.godotengine.godot.Godot;
import org.godotengine.godot.plugin.GodotPlugin;
import org.godotengine.godot.plugin.UsedByGodot;

/**
 * Engine.get_singleton("BibliothecaVivaShare") in GDScript. share() opens Android's share
 * menu for a file in the app's storage, so the user can send it by mail or a chat app, or
 * save it to Files, Downloads or Drive. The file goes out through the FileProvider that
 * Godot's Android library declares ("<package>.fileprovider"), with read access only for
 * the app the user picks.
 */
public class SharePlugin extends GodotPlugin {
	private static final String TAG = "BibliothecaVivaShare";

	public SharePlugin(Godot godot) {
		super(godot);
	}

	@Override
	public String getPluginName() {
		return "BibliothecaVivaShare";
	}

	/** path: absolute path of the file; mime: e.g. "text/plain". -> false when it can't be shared. */
	@UsedByGodot
	public boolean share(String path, String mime, String title) {
		final Activity activity = getActivity();
		if (activity == null) {
			return false;
		}
		try {
			File file = new File(path);
			if (!file.isFile()) {
				return false;
			}
			Uri uri = FileProvider.getUriForFile(activity, activity.getPackageName() + ".fileprovider", file);
			Intent send = new Intent(Intent.ACTION_SEND);
			send.setType(mime);
			send.putExtra(Intent.EXTRA_STREAM, uri);
			send.putExtra(Intent.EXTRA_SUBJECT, title);
			send.setClipData(ClipData.newRawUri(title, uri));  // lets the share menu preview it
			send.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
			final Intent chooser = Intent.createChooser(send, title);
			activity.runOnUiThread(() -> {
				try {
					activity.startActivity(chooser);
				} catch (Exception e) {
					Log.w(TAG, "share menu failed", e);
				}
			});
			return true;
		} catch (Exception e) {
			Log.w(TAG, "share failed", e);
			return false;
		}
	}
}
