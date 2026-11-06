package com.alsderda.bibliotheca_viva.speech;

import java.util.ArrayList;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.graphics.drawable.Icon;
import android.media.AudioAttributes;
import android.media.AudioManager;
import android.media.MediaMetadata;
import android.media.session.MediaSession;
import android.media.session.PlaybackState;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.os.PowerManager;
import android.os.SystemClock;
import android.speech.tts.TextToSpeech;
import android.speech.tts.UtteranceProgressListener;

/**
 * Reads a list of utterances with Android's TextToSpeech, with silences between them.
 *
 * Godot's main loop stops while the app is in the background, so GDScript hands over
 * everything up front (the current chapter and the next few) and this class plays it on
 * its own. It hands the engine only a couple of utterances at a time, so pausing, seeking
 * and speed changes take effect right away. SpeechService keeps the app running behind a
 * media notification while something is playing.
 *
 * Everything runs on the main thread.
 */
final class SpeechPlayer {
	interface Listener {
		void chunkStarted(int session, int index);
		void stateChanged(int session, boolean playing, boolean paused);
		void finished(int session);
		void sleepStopped(int session);
	}

	static final Handler MAIN = new Handler(Looper.getMainLooper());
	static final int NOTIFICATION_ID = 1;
	static final String ACTION_PLAY = "play";
	static final String ACTION_PAUSE = "pause";
	static final String ACTION_PREVIOUS = "previous";
	static final String ACTION_NEXT = "next";
	static final String ACTION_STOP = "stop";
	private static final String CHANNEL = "speech";
	private static final int AHEAD = 2;  // utterances queued with the engine, counting the current one

	/** The live player, for SpeechService. */
	static SpeechPlayer instance;

	private final Context context;
	private final Listener listener;
	private final TextToSpeech tts;
	private final MediaSession media;
	private final AudioManager audio;
	private final PowerManager.WakeLock wakeLock;
	private final AudioManager.OnAudioFocusChangeListener focusListener = change -> MAIN.post(() -> onFocusChange(change));
	private final BroadcastReceiver noisyReceiver = new BroadcastReceiver() {
		@Override
		public void onReceive(Context c, Intent intent) {
			pause();  // headphones unplugged
		}
	};
	private boolean ready;

	private final ArrayList<String> texts = new ArrayList<>();
	private final ArrayList<Integer> gaps = new ArrayList<>();      // ms of silence after each utterance
	private final ArrayList<Integer> chapters = new ArrayList<>();  // index into titles for each utterance
	private String[] titles = new String[0];
	private String book = "";
	private int session;
	private int pos;      // utterance being spoken, or to speak next
	private int queued;   // first utterance not yet handed to the engine
	private int epoch;    // bumps whenever the engine is flushed, so its late callbacks are ignored
	private boolean playing;
	private boolean paused;
	private boolean resumeOnFocus;
	private boolean serviceStarted;
	private boolean noisyRegistered;
	private float volume = 1f;
	private long sleepAt;  // SystemClock.elapsedRealtime() deadline, 0 when off
	private boolean sleepAtChapterEnd;
	private int shownChapter = -1;

	SpeechPlayer(Context context, Listener listener) {
		if (instance != null) {
			instance.release();
		}
		instance = this;
		this.context = context;
		this.listener = listener;
		audio = (AudioManager) context.getSystemService(Context.AUDIO_SERVICE);
		PowerManager power = (PowerManager) context.getSystemService(Context.POWER_SERVICE);
		wakeLock = power.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "bibliotheca-viva:speech");
		wakeLock.setReferenceCounted(false);

		tts = new TextToSpeech(context, status -> MAIN.post(() -> {
			ready = status == TextToSpeech.SUCCESS;
			fill();
		}));
		tts.setAudioAttributes(new AudioAttributes.Builder()
				.setUsage(AudioAttributes.USAGE_MEDIA)
				.setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
				.build());
		tts.setOnUtteranceProgressListener(new UtteranceProgressListener() {
			@Override
			public void onStart(String id) {
				MAIN.post(() -> onUtterance(id, false));
			}

			@Override
			public void onDone(String id) {
				MAIN.post(() -> onUtterance(id, true));
			}

			@Override
			public void onError(String id) {
				MAIN.post(() -> onUtterance(id, true));  // skip it rather than stall
			}
		});

		media = new MediaSession(context, "bibliotheca-viva");
		media.setCallback(new MediaSession.Callback() {
			@Override
			public void onPlay() {
				resume();
			}

			@Override
			public void onPause() {
				pause();
			}

			@Override
			public void onSkipToNext() {
				seek(pos + 1);
			}

			@Override
			public void onSkipToPrevious() {
				seek(pos - 1);
			}

			@Override
			public void onStop() {
				stop();
			}
		}, MAIN);

		if (Build.VERSION.SDK_INT >= 26) {
			NotificationChannel channel = new NotificationChannel(CHANNEL, "Reading aloud", NotificationManager.IMPORTANCE_LOW);
			channel.setShowBadge(false);
			context.getSystemService(NotificationManager.class).createNotificationChannel(channel);
		}
	}

	boolean isPlaying() {
		return playing;
	}

	// --- commands --------------------------------------------------------------

	void configure(int ratePercent, int pitchPercent, int volumePercent) {
		tts.setSpeechRate(ratePercent / 100f);
		tts.setPitch(pitchPercent / 100f);
		volume = volumePercent / 100f;
	}

	void play(int session, String[] texts, int[] gaps, int[] chapters, String[] titles, String book, int start) {
		flush();
		this.texts.clear();
		this.gaps.clear();
		this.chapters.clear();
		this.session = session;
		this.book = book;
		add(texts, gaps, chapters, titles);
		if (this.texts.isEmpty()) {
			halt();
			listener.finished(session);
			return;
		}
		pos = queued = clamp(start);
		playing = true;
		paused = false;
		shownChapter = -1;
		hold();
		fill();
		publish();
	}

	void append(int session, String[] texts, int[] gaps, int[] chapters, String[] titles) {
		if (session != this.session || !playing) {
			return;
		}
		add(texts, gaps, chapters, titles);
		fill();
	}

	void seek(int index) {
		if (!playing) {
			return;
		}
		flush();
		pos = queued = clamp(index);
		paused = false;
		hold();
		fill();
		publish();
	}

	void pause() {
		if (!playing || paused) {
			return;
		}
		flush();
		paused = true;
		wakeLock.release();
		publish();
	}

	void resume() {
		if (!playing || !paused) {
			return;
		}
		paused = false;
		hold();
		fill();
		publish();
	}

	void stop() {
		if (!playing) {
			return;
		}
		halt();
		listener.stateChanged(session, false, false);
	}

	void setSleep(int seconds, boolean endOfChapter) {
		sleepAt = seconds > 0 ? SystemClock.elapsedRealtime() + seconds * 1000L : 0;
		sleepAtChapterEnd = endOfChapter;
	}

	void release() {
		halt();
		tts.shutdown();
		media.release();
		if (instance == this) {
			instance = null;
		}
	}

	/** Notification buttons, through SpeechService. */
	void handle(String action) {
		switch (action) {
			case ACTION_PLAY: resume(); break;
			case ACTION_PAUSE: pause(); break;
			case ACTION_PREVIOUS: seek(pos - 1); break;
			case ACTION_NEXT: seek(pos + 1); break;
			case ACTION_STOP: stop(); break;
		}
	}

	// --- playback --------------------------------------------------------------

	private void add(String[] texts, int[] gaps, int[] chapters, String[] titles) {
		for (int i = 0; i < texts.length; i++) {
			this.texts.add(texts[i]);
			this.gaps.add(gaps[i]);
			this.chapters.add(chapters[i]);
		}
		this.titles = titles;
	}

	private int clamp(int index) {
		return Math.max(0, Math.min(index, texts.size() - 1));
	}

	/** Hands the engine the next utterances, with the silence after each. */
	private void fill() {
		if (!ready || !playing || paused) {
			return;
		}
		int max = TextToSpeech.getMaxSpeechInputLength();
		while (queued < texts.size() && queued < pos + AHEAD) {
			int i = queued;
			if (sleepAtChapterEnd && i > pos && !chapters.get(i).equals(chapters.get(i - 1))) {
				break;  // stopping at the end of this chapter
			}
			String text = texts.get(i);
			Bundle params = new Bundle();
			params.putFloat(TextToSpeech.Engine.KEY_PARAM_VOLUME, volume);
			tts.speak(text.length() > max ? text.substring(0, max) : text, TextToSpeech.QUEUE_ADD, params, epoch + ":" + i);
			if (gaps.get(i) > 0 && i + 1 < texts.size()) {
				tts.playSilentUtterance(gaps.get(i), TextToSpeech.QUEUE_ADD, epoch + ":" + i + ":gap");
			}
			queued++;
		}
	}

	private void onUtterance(String id, boolean done) {
		String[] parts = id.split(":");
		if (Integer.parseInt(parts[0]) != epoch || !playing || paused || parts.length > 2) {
			return;  // stale, or a silence
		}
		int i = Integer.parseInt(parts[1]);
		if (!done) {
			pos = i;
			if (sleepAt > 0 && SystemClock.elapsedRealtime() >= sleepAt) {
				int s = session;
				halt();
				listener.sleepStopped(s);
				return;
			}
			wakeLock.acquire(10 * 60 * 1000L);  // renewed every utterance, so it can't leak for long
			listener.chunkStarted(session, i);
			if (!chapters.get(i).equals(shownChapter)) {
				publish();
			}
			return;
		}
		pos = i + 1;
		if (pos >= texts.size() || (sleepAtChapterEnd && !chapters.get(pos).equals(chapters.get(i)))) {
			int s = session;
			halt();
			listener.finished(s);
			return;
		}
		fill();
	}

	/** Drops whatever the engine still has queued; playback continues from `pos`. */
	private void flush() {
		epoch++;
		queued = pos;
		if (ready) {
			tts.stop();
		}
	}

	private void halt() {
		flush();
		playing = false;
		paused = false;
		resumeOnFocus = false;
		texts.clear();
		gaps.clear();
		chapters.clear();
		wakeLock.release();
		audio.abandonAudioFocus(focusListener);
		if (noisyRegistered) {
			context.unregisterReceiver(noisyReceiver);
			noisyRegistered = false;
		}
		publish();
	}

	/** Takes audio focus and keeps the CPU awake while speaking. */
	private void hold() {
		audio.requestAudioFocus(focusListener, AudioManager.STREAM_MUSIC, AudioManager.AUDIOFOCUS_GAIN);
		wakeLock.acquire(10 * 60 * 1000L);
		if (!noisyRegistered) {
			context.registerReceiver(noisyReceiver, new IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY));
			noisyRegistered = true;
		}
	}

	private void onFocusChange(int change) {
		if (change == AudioManager.AUDIOFOCUS_LOSS_TRANSIENT) {  // e.g. a phone call
			if (playing && !paused) {
				pause();
				resumeOnFocus = true;
			}
		} else if (change == AudioManager.AUDIOFOCUS_LOSS) {  // another app started playing
			resumeOnFocus = false;
			pause();
		} else if (change == AudioManager.AUDIOFOCUS_GAIN && resumeOnFocus) {
			resumeOnFocus = false;
			resume();
		}
	}

	// --- media session and notification ----------------------------------------

	/** Updates the media session, the notification and the service, and tells Godot. */
	private void publish() {
		int state = !playing ? PlaybackState.STATE_STOPPED : paused ? PlaybackState.STATE_PAUSED : PlaybackState.STATE_PLAYING;
		media.setPlaybackState(new PlaybackState.Builder()
				.setActions(PlaybackState.ACTION_PLAY | PlaybackState.ACTION_PAUSE | PlaybackState.ACTION_PLAY_PAUSE
						| PlaybackState.ACTION_SKIP_TO_NEXT | PlaybackState.ACTION_SKIP_TO_PREVIOUS | PlaybackState.ACTION_STOP)
				.setState(state, PlaybackState.PLAYBACK_POSITION_UNKNOWN, 1f)
				.build());
		if (playing) {
			shownChapter = chapters.get(pos);
			media.setMetadata(new MediaMetadata.Builder()
					.putString(MediaMetadata.METADATA_KEY_TITLE, chapterTitle())
					.putString(MediaMetadata.METADATA_KEY_ARTIST, book)
					.putString(MediaMetadata.METADATA_KEY_ALBUM, book)
					.build());
			media.setActive(true);
			if (serviceStarted) {
				context.getSystemService(NotificationManager.class).notify(NOTIFICATION_ID, notification());
			} else {
				Intent intent = new Intent(context, SpeechService.class);
				if (Build.VERSION.SDK_INT >= 26) {
					context.startForegroundService(intent);
				} else {
					context.startService(intent);
				}
				serviceStarted = true;
			}
			listener.stateChanged(session, true, paused);
		} else {
			media.setActive(false);
			if (serviceStarted) {
				context.stopService(new Intent(context, SpeechService.class));
				serviceStarted = false;
			}
		}
	}

	private String chapterTitle() {
		int chapter = chapters.get(pos);
		return chapter < titles.length ? titles[chapter] : "";
	}

	Notification notification() {
		Notification.Builder builder = Build.VERSION.SDK_INT >= 26
				? new Notification.Builder(context, CHANNEL)
				: new Notification.Builder(context);
		Intent open = context.getPackageManager().getLaunchIntentForPackage(context.getPackageName());
		builder.setSmallIcon(android.R.drawable.ic_media_play)
				.setContentTitle(playing ? chapterTitle() : "")
				.setContentText(book)
				.setVisibility(Notification.VISIBILITY_PUBLIC)
				.setShowWhen(false)
				.setContentIntent(open == null ? null : PendingIntent.getActivity(context, 0, open, PendingIntent.FLAG_IMMUTABLE))
				.setDeleteIntent(action(ACTION_STOP))
				.addAction(button(android.R.drawable.ic_media_previous, "Previous", ACTION_PREVIOUS))
				.addAction(paused
						? button(android.R.drawable.ic_media_play, "Play", ACTION_PLAY)
						: button(android.R.drawable.ic_media_pause, "Pause", ACTION_PAUSE))
				.addAction(button(android.R.drawable.ic_media_next, "Next", ACTION_NEXT))
				.addAction(button(android.R.drawable.ic_menu_close_clear_cancel, "Stop", ACTION_STOP))
				.setStyle(new Notification.MediaStyle()
						.setMediaSession(media.getSessionToken())
						.setShowActionsInCompactView(0, 1, 2));
		return builder.build();
	}

	private Notification.Action button(int icon, String title, String action) {
		return new Notification.Action.Builder(Icon.createWithResource(context, icon), title, action(action)).build();
	}

	private PendingIntent action(String action) {
		Intent intent = new Intent(context, SpeechService.class).setAction(action);
		return PendingIntent.getService(context, action.hashCode(), intent, PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
	}
}
