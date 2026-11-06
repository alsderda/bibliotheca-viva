package com.alsderda.bibliotheca_viva.speech;

import android.app.Service;
import android.content.Intent;
import android.content.pm.ServiceInfo;
import android.os.Build;
import android.os.IBinder;

/**
 * Foreground service that keeps the app alive while SpeechPlayer is reading, so Android
 * doesn't stop it in the background. It also receives the notification's buttons.
 */
public class SpeechService extends Service {
	@Override
	public int onStartCommand(Intent intent, int flags, int startId) {
		SpeechPlayer player = SpeechPlayer.instance;
		if (player == null) {
			stopSelf();
			return START_NOT_STICKY;
		}
		if (Build.VERSION.SDK_INT >= 29) {
			startForeground(SpeechPlayer.NOTIFICATION_ID, player.notification(), ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK);
		} else {
			startForeground(SpeechPlayer.NOTIFICATION_ID, player.notification());
		}
		if (intent != null && intent.getAction() != null) {
			player.handle(intent.getAction());
		}
		if (!player.isPlaying()) {
			stopSelf();
		}
		return START_NOT_STICKY;
	}

	/** The app was swiped away: stop rather than keep talking with no way back to it. */
	@Override
	public void onTaskRemoved(Intent rootIntent) {
		SpeechPlayer player = SpeechPlayer.instance;
		if (player != null) {
			player.stop();
		}
		stopSelf();
	}

	@Override
	public void onDestroy() {
		stopForeground(STOP_FOREGROUND_REMOVE);
		super.onDestroy();
	}

	@Override
	public IBinder onBind(Intent intent) {
		return null;
	}
}
