package com.alsderda.bibliotheca_viva.speech;

import java.io.File;
import java.io.FileInputStream;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.HashSet;
import java.util.concurrent.LinkedBlockingQueue;

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
import android.media.AudioFormat;
import android.media.AudioManager;
import android.media.AudioTrack;
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
 * its own. It synthesizes a few utterances ahead of playback into files, then feeds the
 * audio through one streaming AudioTrack of its own instead of the framework's playback:
 * the framework stops utterances smaller than its track buffer, which can go unheard on
 * some outputs (e.g. Bluetooth), while a track that stays open and fed has no short
 * utterances at all. Spoken events fire off the track's playback head, watched by a
 * delayed handler that wakes for the next event's frame.
 *
 * Everything lives on the main thread, except file reads on the synthesis callbacks and
 * one writer thread that only writes the byte arrays it is handed and frees its own track.
 */
final class SpeechPlayer {
	interface Listener {
		void chunkStarted(int session, int index);
		void wordRange(int session, int index, int start, int end);
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
	private static final int AHEAD = 3;  // utterances past the one playing, synthesized or synthesizing

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
	private final File speechDir;
	private final Runnable checks = new Runnable() {
		@Override
		public void run() {
			checksScheduled = false;
			if (scheduledRun != run) {
				return;  // the run turned over while this was queued
			}
			checkPos();
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
	private int epoch;    // bumps whenever synthesis is discarded, so its late callbacks are ignored
	private boolean playing;
	private boolean paused;
	private boolean resumeOnFocus;
	private boolean serviceStarted;
	private boolean noisyRegistered;
	private float volume = 1f;
	private float ratePct = 1f;
	private float pitchPct = 1f;
	private long sleepAt;  // SystemClock.elapsedRealtime() deadline, 0 when off
	private boolean sleepAtChapterEnd;
	private int shownChapter = -1;

	// One run's streaming playback: a single track fed by a single writer thread.
	private int run;      // bumps whenever the writer/track turn over, so late checks stop
	private AudioTrack track;
	private Writer writer;
	private long framesFed;     // audio, gap and padding frames handed to the writer this run
	private long lastAudioEnd;  // end of the last fed utterance's audio, where the finish fires
	private int feedPos;        // first utterance not yet handed to the writer
	private long head;          // absolute playback head, across getPlaybackHeadPosition wraps
	private int lastRaw;
	private int sampleRate;
	private int channelMask;
	private int encoding;
	private int frameBytes;
	private int bufferFrames;
	private final ArrayList<Event> events = new ArrayList<>();  // fired in order as the head reaches them
	private int eventPos;       // first event not yet fired
	private int finishAt = -1;  // index of the pending finish event, or -1
	private int chainIndex = -1;  // a format change restarts the run here once the head arrives
	private boolean checksScheduled;
	private int scheduledRun;
	private final HashMap<Integer, Clip> clips = new HashMap<>();  // synthesized, not yet fed
	private final HashSet<Integer> synthesizing = new HashSet<>();
	private final HashMap<Integer, ArrayList<int[]>> pendingRanges = new HashMap<>();

	SpeechPlayer(Context context, Listener listener) {
		if (instance != null) {
			instance.release();
		}
		instance = this;
		this.context = context;
		this.listener = listener;
		speechDir = new File(context.getCacheDir(), "speech");
		speechDir.mkdirs();
		cleanCache();
		audio = (AudioManager) context.getSystemService(Context.AUDIO_SERVICE);
		PowerManager power = (PowerManager) context.getSystemService(Context.POWER_SERVICE);
		wakeLock = power.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "bibliotheca-viva:speech");
		wakeLock.setReferenceCounted(false);

		tts = new TextToSpeech(context, status -> MAIN.post(() -> {
			ready = status == TextToSpeech.SUCCESS;
			pump();
		}));
		tts.setAudioAttributes(new AudioAttributes.Builder()
				.setUsage(AudioAttributes.USAGE_MEDIA)
				.setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
				.build());
		tts.setOnUtteranceProgressListener(new UtteranceProgressListener() {
			@Override
			public void onStart(String id) {
				// synthesis started: nothing to show until its audio plays
			}

			@Override
			public void onDone(String id) {
				readClip(id);  // binder thread: reads the file, then posts the clip
			}

			@Override
			public void onError(String id) {
				MAIN.post(() -> onSynthError(id));
			}

			@Override
			public void onError(String id, int errorCode) {
				MAIN.post(() -> onSynthError(id));
			}

			// The audio frame arrives in the start slot: the framework forwards
			// rangeStart(markerInFrames, start, end) positionally into these
			// (start, end, frame) slots, while the playback path sends them straight.
			@Override
			public void onRangeStart(String id, int start, int end, int frame) {
				MAIN.post(() -> onSynthRange(id, start, end, frame));
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
		float rate = ratePercent / 100f;
		float pitch = pitchPercent / 100f;
		tts.setSpeechRate(rate);
		tts.setPitch(pitch);
		volume = volumePercent / 100f;
		if (track != null) {
			track.setVolume(volume);
		}
		if (rate != ratePct || pitch != pitchPct) {
			ratePct = rate;
			pitchPct = pitch;
			if (ready) {
				tts.stop();  // cancels in-flight synthesis; its files are dropped below
			}
			dropSynth(epoch);
			epoch++;
			pump();  // re-synthesizes everything not yet played with the new settings
		}
	}

	void play(int session, String[] texts, int[] gaps, int[] chapters, String[] titles, String book, int start) {
		endRun();
		if (ready) {
			tts.stop();
		}
		dropSynth(epoch);
		epoch++;
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
		pos = clamp(start);
		playing = true;
		paused = false;
		shownChapter = -1;
		hold();
		startRun(pos);
		publish();
	}

	void append(int session, String[] texts, int[] gaps, int[] chapters, String[] titles) {
		if (session != this.session || !playing) {
			return;
		}
		add(texts, gaps, chapters, titles);
		if (finishAt >= 0 && eventPos <= finishAt) {  // more to say: the pending finish is off
			events.remove(finishAt);
			finishAt = -1;
		}
		pump();
	}

	void seek(int index) {
		if (!playing) {
			return;
		}
		endRun();
		if (ready) {
			tts.stop();
		}
		for (int i : synthesizing) {
			synthFile(epoch, i).delete();
		}
		synthesizing.clear();
		pendingRanges.clear();
		epoch++;
		int at = clamp(index);
		clips.keySet().removeIf(k -> k < at || k > at + AHEAD);  // keeps current synthesis
		pos = at;
		paused = false;
		hold();
		startRun(at);
		publish();
	}

	void pause() {
		if (!playing || paused) {
			return;
		}
		if (track != null) {
			track.pause();
		}
		MAIN.removeCallbacks(checks);
		checksScheduled = false;
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
		if (track != null) {
			track.play();  // continues mid-sentence where it left off
		}
		pump();
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
		cleanCache();
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

	// --- synthesis and playback ------------------------------------------------

	private void pump() {
		pumpSynth();
		pumpFeed();
		if (playing && !paused && track != null) {
			MAIN.removeCallbacks(checks);
			checksScheduled = false;
			checkPos();  // fires anything already due, then watches for the next event
		}
	}

	/** Synthesizes ahead of playback, keeping a few utterances past the one playing ready or in flight. */
	private void pumpSynth() {
		if (!ready || !playing || paused) {
			return;
		}
		int end = limit();
		for (int i = Math.max(feedPos, pos); i <= pos + AHEAD && i < end; i++) {
			if (clips.containsKey(i) || !synthesizing.add(i)) {
				continue;
			}
			File file = synthFile(epoch, i);
			if (tts.synthesizeToFile(text(i), new Bundle(), file, epoch + ":" + i) != TextToSpeech.SUCCESS) {
				synthesizing.remove(i);
				file.delete();
				clips.put(i, Clip.empty());
			}
		}
	}

	/**
	 * Hands synthesized clips to the writer in order, finishing the run once its audio is all fed.
	 * Only the next utterance goes in ahead of the one playing, so a rate change is heard soon,
	 * unless the track holds less than two buffers: a streaming track waits for a full buffer
	 * before it starts playing.
	 */
	private void pumpFeed() {
		if (!playing || paused) {
			return;
		}
		while (playing && chainIndex < 0 && feedPos < limit() && clips.containsKey(feedPos)
				&& (feedPos <= pos + 1 || framesFed - head < 2L * bufferFrames)) {
			feedClip(feedPos, clips.get(feedPos));
			if (chainIndex < 0) {
				clips.remove(feedPos);
				feedPos++;
			}
		}
		if (playing && !paused && chainIndex < 0 && feedPos >= limit() && finishAt < 0) {
			finishRun();
		}
	}

	/** Writes one clip's audio plus its gap; on a format change pads this run and chains the next. */
	private void feedClip(int i, Clip clip) {
		if (clip.frames > 0) {
			if (track == null) {
				ensureTrack(clip);
				if (track == null) {
					return;  // the track failed: ensureTrack ended everything
				}
			} else if (!sameFormat(clip)) {
				byte[] pad = new byte[bufferFrames * frameBytes];
				writer.queue.add(pad);
				events.add(new Event(framesFed, Event.CHAIN, i, 0, 0));
				framesFed += bufferFrames;
				chainIndex = i;
				return;
			}
			events.add(new Event(framesFed, Event.CHUNK, i, 0, 0));
			writer.queue.add(clip.pcm);
			for (int[] range : clip.ranges) {
				events.add(new Event(framesFed + Math.min(range[0], clip.frames), Event.RANGE, i, range[1], range[2]));
			}
			framesFed += clip.frames;
			lastAudioEnd = framesFed;
		} else {
			events.add(new Event(framesFed, Event.CHUNK, i, 0, 0));
			lastAudioEnd = framesFed;
		}
		if (track != null) {
			int gapFrames = (int) (gaps.get(i) * (long) sampleRate / 1000);
			if (gapFrames > 0) {
				writer.queue.add(new byte[gapFrames * frameBytes]);
				framesFed += gapFrames;
			}
		}
	}

	/** Opens the run's track from the first clip with audio; every clip after it must match. */
	private void ensureTrack(Clip clip) {
		sampleRate = clip.sampleRate;
		channelMask = clip.channels == 1 ? AudioFormat.CHANNEL_OUT_MONO : AudioFormat.CHANNEL_OUT_STEREO;
		encoding = clip.encoding;
		frameBytes = clip.channels * clip.bytesPerSample;
		int min = AudioTrack.getMinBufferSize(sampleRate, channelMask, encoding);
		if (min <= 0) {
			min = sampleRate * frameBytes / 5;
		}
		bufferFrames = (Math.max(2 * min, sampleRate * frameBytes / 5) + frameBytes - 1) / frameBytes;
		track = new AudioTrack(new AudioAttributes.Builder()
				.setUsage(AudioAttributes.USAGE_MEDIA)
				.setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
				.build(),
			new AudioFormat.Builder()
				.setSampleRate(sampleRate)
				.setChannelMask(channelMask)
				.setEncoding(encoding)
				.build(),
			bufferFrames * frameBytes, AudioTrack.MODE_STREAM, AudioManager.AUDIO_SESSION_ID_GENERATE);
		if (track.getState() != AudioTrack.STATE_INITIALIZED) {
			track.release();
			track = null;
			int s = session;
			halt();
			listener.finished(s);
			return;
		}
		track.setVolume(volume);
		track.play();
		writer = new Writer(track);
		writer.start();
		lastRaw = track.getPlaybackHeadPosition();
	}

	private boolean sameFormat(Clip clip) {
		return clip.sampleRate == sampleRate
			&& (clip.channels == 1 ? AudioFormat.CHANNEL_OUT_MONO : AudioFormat.CHANNEL_OUT_STEREO) == channelMask
			&& clip.encoding == encoding;
	}

	/** Pads the run past its last audio so it is all pushed out, and ends it once the head gets there. */
	private void finishRun() {
		if (track == null) {  // every clip was empty: nothing will ever play
			int s = session;
			halt();
			listener.finished(s);
			return;
		}
		writer.queue.add(new byte[bufferFrames * frameBytes]);
		framesFed += bufferFrames;
		events.add(new Event(lastAudioEnd, Event.FINISH, 0, 0, 0));
		finishAt = events.size() - 1;
	}

	/** First utterance not to play: the texts' end, or the chapter boundary past `pos`. */
	private int limit() {
		if (!sleepAtChapterEnd) {
			return texts.size();
		}
		for (int k = pos + 1; k < texts.size(); k++) {
			if (!chapters.get(k).equals(chapters.get(k - 1))) {
				return k;
			}
		}
		return texts.size();
	}

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

	private String text(int i) {
		String t = texts.get(i);
		int max = TextToSpeech.getMaxSpeechInputLength();
		return t.length() > max ? t.substring(0, max) : t;
	}

	private File synthFile(int e, int i) {
		return new File(speechDir, e + "_" + i + ".wav");
	}

	/** Drops synthesis in flight and clips not yet played; late callbacks die on the epoch. */
	private void dropSynth(int e) {
		for (int i : synthesizing) {
			synthFile(e, i).delete();
		}
		synthesizing.clear();
		pendingRanges.clear();
		clips.clear();
	}

	private void cleanCache() {
		File[] files = speechDir.listFiles();
		if (files != null) {
			for (File f : files) {
				f.delete();
			}
		}
	}

	/** Begins a writer/track turn at utterance `at`; synthesized clips stay cached across runs. */
	private void startRun(int at) {
		run++;
		feedPos = at;
		framesFed = 0;
		lastAudioEnd = 0;
		head = 0;
		lastRaw = 0;
		events.clear();
		eventPos = 0;
		finishAt = -1;
		chainIndex = -1;
		pump();
	}

	/** Ends the writer/track turn: late checks die with the run, the writer frees its own track. */
	private void endRun() {
		run++;
		MAIN.removeCallbacks(checks);
		checksScheduled = false;
		if (writer != null) {
			writer.cancelled = true;
		}
		if (track != null) {
			track.pause();
			track.flush();  // wakes a write blocked on a full buffer, so the writer can exit
		}
		if (writer != null) {
			writer.interrupt();
			writer = null;
		}
		track = null;
		events.clear();
		eventPos = 0;
		finishAt = -1;
		chainIndex = -1;
	}

	private void halt() {
		endRun();
		if (ready) {
			tts.stop();
		}
		dropSynth(epoch);
		epoch++;
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

	// --- synthesis callbacks ---------------------------------------------------

	/** Binder thread: reads the finished file, then hands the clip to the main thread. */
	private void readClip(String id) {
		int[] parsed = parseId(id);
		if (parsed == null) {
			return;
		}
		File file = synthFile(parsed[0], parsed[1]);
		Clip clip = Clip.read(file);
		MAIN.post(() -> onClipReady(parsed[0], parsed[1], clip));
	}

	private void onClipReady(int e, int i, Clip clip) {
		if (e != epoch || !playing || !synthesizing.remove(i)) {
			return;  // a seek, stop or retune moved on
		}
		if (clip.frames > 0) {
			ArrayList<int[]> ranges = pendingRanges.remove(i);
			if (ranges != null) {
				ranges.sort((a, b) -> a[0] - b[0]);
				clip.ranges = ranges;
			}
		}
		clips.put(i, clip);
		pump();
	}

	/** A failed synthesis becomes an empty clip: skipped, but its gap still plays. */
	private void onSynthError(String id) {
		int[] parsed = parseId(id);
		if (parsed == null || parsed[0] != epoch || !playing || !synthesizing.remove(parsed[1])) {
			return;
		}
		synthFile(parsed[0], parsed[1]).delete();
		clips.put(parsed[1], Clip.empty());
		pump();
	}

	private void onSynthRange(String id, int frame, int start, int end) {
		int[] parsed = parseId(id);
		if (parsed == null || parsed[0] != epoch || !playing || !synthesizing.contains(parsed[1])) {
			return;
		}
		int i = parsed[1];
		if (i >= texts.size() || frame < 0 || start < 0 || end < start || end > texts.get(i).length()) {
			return;
		}
		ArrayList<int[]> ranges = pendingRanges.get(i);
		if (ranges == null) {
			ranges = new ArrayList<>();
			pendingRanges.put(i, ranges);
		}
		ranges.add(new int[]{frame, start, end});
	}

	/** Splits an "epoch:index" utterance id, or null when it isn't ours. */
	private static int[] parseId(String id) {
		String[] parts = id.split(":");
		if (parts.length != 2) {
			return null;
		}
		try {
			return new int[]{Integer.parseInt(parts[0]), Integer.parseInt(parts[1])};
		} catch (NumberFormatException e) {
			return null;
		}
	}

	// --- position checks -------------------------------------------------------

	/** Fires the spoken events whose frame the head has reached, then watches for the next one. */
	private void checkPos() {
		if (!playing || paused || track == null) {
			return;
		}
		int raw = track.getPlaybackHeadPosition();
		head += (raw - lastRaw) & 0xffffffffL;
		lastRaw = raw;
		int r = run;
		int s = session;
		while (eventPos < events.size() && events.get(eventPos).frame <= head) {
			Event e = events.get(eventPos++);
			if (e.kind == Event.RANGE) {
				listener.wordRange(s, e.index, e.start, e.end);
			} else if (e.kind == Event.CHUNK) {
				pos = e.index;
				if (sleepAt > 0 && SystemClock.elapsedRealtime() >= sleepAt) {
					halt();
					listener.sleepStopped(s);
					return;
				}
				wakeLock.acquire(10 * 60 * 1000L);  // renewed every utterance, so it can't leak for long
				listener.chunkStarted(s, e.index);
				if (!chapters.get(e.index).equals(shownChapter)) {
					publish();
				}
			} else if (e.kind == Event.FINISH) {
				halt();
				listener.finished(s);
				return;
			} else {
				endRun();
				startRun(e.index);  // new format: restarts seamlessly where the head is
				return;
			}
			if (r != run) {  // a signal re-entered (e.g. seek): the run turned over under us
				return;
			}
		}
		if (eventPos > 64) {  // a book is long: drops fired events
			events.subList(0, eventPos).clear();
			if (finishAt >= 0) {
				finishAt -= eventPos;
			}
			eventPos = 0;
		}
		pumpSynth();  // `pos` and the head moved on: synthesize and feed further
		pumpFeed();
		if (r == run) {
			scheduleChecks();
		}
	}

	/** Wakes for the next event's frame, or just keeps the run alive while synthesis lags. */
	private void scheduleChecks() {
		if (checksScheduled || !playing || paused || track == null) {
			return;
		}
		long delay = 200;
		if (eventPos < events.size()) {
			delay = (events.get(eventPos).frame - head) * 1000 / sampleRate;
		}
		checksScheduled = true;
		scheduledRun = run;
		MAIN.postDelayed(checks, Math.max(10, Math.min(200, delay)));
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

	// --- helpers ---------------------------------------------------------------

	/**
	 * Feeds one run's track, blocking. Only touches what it is handed; the main thread
	 * pauses and flushes the track to wake a blocked write, then this frees the track.
	 */
	private static final class Writer extends Thread {
		final LinkedBlockingQueue<byte[]> queue = new LinkedBlockingQueue<>();
		volatile boolean cancelled;
		private final AudioTrack track;

		Writer(AudioTrack track) {
			this.track = track;
		}

		@Override
		public void run() {
			try {
				while (!cancelled) {
					byte[] chunk = queue.take();
					for (int off = 0; off < chunk.length && !cancelled; ) {
						int wrote = track.write(chunk, off, chunk.length - off);
						if (wrote < 0) {
							break;
						}
						if (wrote == 0) {
							Thread.sleep(20);  // a paused track with a full buffer takes nothing
						}
						off += wrote;
					}
				}
			} catch (InterruptedException e) {
				// the run ended
			} finally {
				track.release();
			}
		}
	}

	/** A spoken event fired once the head reaches its frame. */
	private static final class Event {
		static final int CHUNK = 0;
		static final int RANGE = 1;
		static final int FINISH = 2;
		static final int CHAIN = 3;
		final long frame;
		final int kind;
		final int index;
		final int start;
		final int end;

		Event(long frame, int kind, int index, int start, int end) {
			this.frame = frame;
			this.kind = kind;
			this.index = index;
			this.start = start;
			this.end = end;
		}
	}

	/** One synthesized utterance, held in memory in the track's format. Empty when it failed. */
	private static final class Clip {
		final byte[] pcm;
		final int frames;
		final int sampleRate;
		final int channels;
		final int encoding;
		final int bytesPerSample;
		ArrayList<int[]> ranges = new ArrayList<>();  // (audio frame, text start, text end)

		Clip(byte[] pcm, int frames, int sampleRate, int channels, int encoding, int bytesPerSample) {
			this.pcm = pcm;
			this.frames = frames;
			this.sampleRate = sampleRate;
			this.channels = channels;
			this.encoding = encoding;
			this.bytesPerSample = bytesPerSample;
		}

		static Clip empty() {
			return new Clip(new byte[0], 0, 0, 0, 0, 0);
		}

		/** Reads and parses the WAV, deleting the file either way. */
		static Clip read(File file) {
			try {
				long len = file.length();
				if (len <= 0 || len > 16 * 1024 * 1024) {
					return empty();
				}
				byte[] wav = new byte[(int) len];
				FileInputStream in = new FileInputStream(file);
				try {
					int off = 0;
					while (off < wav.length) {
						int n = in.read(wav, off, wav.length - off);
						if (n < 0) {
							break;
						}
						off += n;
					}
				} finally {
					in.close();
				}
				return parse(wav);
			} catch (Exception e) {
				return empty();
			} finally {
				file.delete();
			}
		}

		/** Walks the RIFF chunks for "fmt " and "data" instead of assuming a 44-byte header. */
		private static Clip parse(byte[] wav) {
			if (wav.length < 12 || wav[0] != 'R' || wav[1] != 'I' || wav[2] != 'F' || wav[3] != 'F'
					|| wav[8] != 'W' || wav[9] != 'A' || wav[10] != 'V' || wav[11] != 'E') {
				return empty();
			}
			int fmt = -1;
			int channels = 0;
			int rate = 0;
			int bits = 0;
			int dataOff = -1;
			int dataLen = 0;
			int pos = 12;
			while (pos >= 12 && pos + 8 <= wav.length) {
				int size = le32(wav, pos + 4);
				int body = pos + 8;
				if (wav[pos] == 'f' && wav[pos + 1] == 'm' && wav[pos + 2] == 't' && wav[pos + 3] == ' ') {
					if (size >= 16 && body + 16 <= wav.length) {
						fmt = le16(wav, body);
						channels = le16(wav, body + 2);
						rate = le32(wav, body + 4);
						bits = le16(wav, body + 14);
					}
				} else if (wav[pos] == 'd' && wav[pos + 1] == 'a' && wav[pos + 2] == 't' && wav[pos + 3] == 'a') {
					dataOff = body;
					dataLen = Math.min(size, wav.length - body);
				}
				pos = body + size + (size & 1);
			}
			if (dataOff < 0 || rate <= 0 || (channels != 1 && channels != 2)) {
				return empty();
			}
			// Everything becomes 16-bit: AudioTrack.write(byte[]) refuses float tracks, and
			// silence in 8-bit PCM isn't zero bytes, while the gaps are written as zeros.
			int bytes;
			if (fmt == 1 && (bits == 8 || bits == 16)) {
				bytes = bits / 8;
			} else if (fmt == 3 && bits == 32) {
				bytes = 4;
			} else {
				return empty();
			}
			int samples = dataLen / bytes;
			samples -= samples % channels;
			if (samples <= 0) {
				return empty();
			}
			byte[] pcm = new byte[samples * 2];
			if (bytes == 2) {
				System.arraycopy(wav, dataOff, pcm, 0, pcm.length);
			} else {
				for (int k = 0; k < samples; k++) {
					int s;
					if (bytes == 1) {
						s = ((wav[dataOff + k] & 0xff) - 128) << 8;
					} else {
						float f = Float.intBitsToFloat(le32(wav, dataOff + 4 * k));
						s = Math.round(Math.max(-1f, Math.min(1f, f)) * 32767f);
					}
					pcm[2 * k] = (byte) s;
					pcm[2 * k + 1] = (byte) (s >> 8);
				}
			}
			return new Clip(pcm, samples / channels, rate, channels, AudioFormat.ENCODING_PCM_16BIT, 2);
		}

		private static int le16(byte[] b, int off) {
			return (b[off] & 0xff) | ((b[off + 1] & 0xff) << 8);
		}

		private static int le32(byte[] b, int off) {
			return (b[off] & 0xff) | ((b[off + 1] & 0xff) << 8) | ((b[off + 2] & 0xff) << 16) | ((b[off + 3] & 0xff) << 24);
		}
	}
}
