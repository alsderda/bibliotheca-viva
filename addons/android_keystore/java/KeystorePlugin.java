package com.alsderda.bibliotheca_viva.keystore;

import android.security.keystore.KeyGenParameterSpec;
import android.security.keystore.KeyProperties;
import android.util.Base64;
import android.util.Log;

import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.security.KeyStore;

import javax.crypto.Cipher;
import javax.crypto.KeyGenerator;
import javax.crypto.SecretKey;
import javax.crypto.spec.GCMParameterSpec;

import org.godotengine.godot.Godot;
import org.godotengine.godot.plugin.GodotPlugin;
import org.godotengine.godot.plugin.UsedByGodot;

/**
 * Engine.get_singleton("BibliothecaVivaKeystore") in GDScript; used by scripts/core/keyring.gd.
 * seal() encrypts text with an AES-GCM key that lives in the Android Keystore and can't be
 * read out of it; open() reverses that. The app stores the sealed text in its own files.
 * Both return "" on failure.
 */
public class KeystorePlugin extends GodotPlugin {
	private static final String TAG = "BibliothecaVivaKeystore";
	private static final String STORE = "AndroidKeyStore";
	private static final String ALIAS = "bibliotheca-viva-secrets";
	private static final String TRANSFORM = "AES/GCM/NoPadding";
	private static final int TAG_BITS = 128;

	public KeystorePlugin(Godot godot) {
		super(godot);
	}

	@Override
	public String getPluginName() {
		return "BibliothecaVivaKeystore";
	}

	private static synchronized SecretKey key() throws Exception {
		KeyStore ks = KeyStore.getInstance(STORE);
		ks.load(null);
		if (ks.containsAlias(ALIAS)) {
			return ((KeyStore.SecretKeyEntry) ks.getEntry(ALIAS, null)).getSecretKey();
		}
		KeyGenerator gen = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, STORE);
		gen.init(new KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT | KeyProperties.PURPOSE_DECRYPT)
				.setBlockModes(KeyProperties.BLOCK_MODE_GCM)
				.setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
				.setKeySize(256)
				.build());
		return gen.generateKey();
	}

	/** -> base64 of (IV length, IV, ciphertext), or "". */
	@UsedByGodot
	public String seal(String text) {
		try {
			Cipher c = Cipher.getInstance(TRANSFORM);
			c.init(Cipher.ENCRYPT_MODE, key());
			byte[] iv = c.getIV();
			byte[] data = c.doFinal(text.getBytes(StandardCharsets.UTF_8));
			ByteBuffer out = ByteBuffer.allocate(1 + iv.length + data.length);
			out.put((byte) iv.length).put(iv).put(data);
			return Base64.encodeToString(out.array(), Base64.NO_WRAP);
		} catch (Exception e) {
			Log.w(TAG, "seal failed", e);
			return "";
		}
	}

	@UsedByGodot
	public String open(String sealed) {
		try {
			ByteBuffer in = ByteBuffer.wrap(Base64.decode(sealed, Base64.NO_WRAP));
			byte[] iv = new byte[in.get() & 0xff];
			in.get(iv);
			byte[] data = new byte[in.remaining()];
			in.get(data);
			Cipher c = Cipher.getInstance(TRANSFORM);
			c.init(Cipher.DECRYPT_MODE, key(), new GCMParameterSpec(TAG_BITS, iv));
			return new String(c.doFinal(data), StandardCharsets.UTF_8);
		} catch (Exception e) {
			Log.w(TAG, "open failed", e);
			return "";
		}
	}
}
