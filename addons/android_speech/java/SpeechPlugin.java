package com.alsderda.bibliotheca_viva.speech;

import java.util.HashSet;
import java.util.Set;

import org.godotengine.godot.Godot;
import org.godotengine.godot.plugin.GodotPlugin;
import org.godotengine.godot.plugin.SignalInfo;
import org.godotengine.godot.plugin.UsedByGodot;

/**
 * Engine.get_singleton("BibliothecaVivaSpeech") in GDScript; used by scripts/core/speech.gd.
 * Calls are handed to SpeechPlayer on the main thread. Numbers are passed as ints
 * (percentages, seconds) because those cross JNI most reliably.
 */
public class SpeechPlugin extends GodotPlugin implements SpeechPlayer.Listener {
	private SpeechPlayer player;

	public SpeechPlugin(Godot godot) {
		super(godot);
	}

	@Override
	public String getPluginName() {
		return "BibliothecaVivaSpeech";
	}

	@Override
	public Set<SignalInfo> getPluginSignals() {
		Set<SignalInfo> signals = new HashSet<>();
		signals.add(new SignalInfo("chunk_started", Integer.class, Integer.class));
		signals.add(new SignalInfo("state_changed", Integer.class, Boolean.class, Boolean.class));
		signals.add(new SignalInfo("finished", Integer.class));
		signals.add(new SignalInfo("sleep_stopped", Integer.class));
		return signals;
	}

	private void run(Runnable action) {
		SpeechPlayer.MAIN.post(() -> {
			if (player == null) {
				player = new SpeechPlayer(getActivity().getApplicationContext(), this);
			}
			action.run();
		});
	}

	@UsedByGodot
	public void configure(int ratePercent, int pitchPercent, int volumePercent) {
		run(() -> player.configure(ratePercent, pitchPercent, volumePercent));
	}

	@UsedByGodot
	public void play(int session, String[] texts, int[] gaps, int[] chapters, String[] titles, String book, int start) {
		run(() -> player.play(session, texts, gaps, chapters, titles, book, start));
	}

	@UsedByGodot
	public void append(int session, String[] texts, int[] gaps, int[] chapters, String[] titles) {
		run(() -> player.append(session, texts, gaps, chapters, titles));
	}

	@UsedByGodot
	public void seek(int index) {
		run(() -> player.seek(index));
	}

	@UsedByGodot
	public void pause() {
		run(() -> player.pause());
	}

	@UsedByGodot
	public void resume() {
		run(() -> player.resume());
	}

	@UsedByGodot
	public void stop() {
		run(() -> player.stop());
	}

	@UsedByGodot
	public void setSleep(int seconds, boolean endOfChapter) {
		run(() -> player.setSleep(seconds, endOfChapter));
	}

	@Override
	public void onMainDestroy() {
		SpeechPlayer.MAIN.post(() -> {
			if (player != null) {
				player.release();
				player = null;
			}
		});
	}

	@Override
	public void chunkStarted(int session, int index) {
		emitSignal("chunk_started", session, index);
	}

	@Override
	public void stateChanged(int session, boolean playing, boolean paused) {
		emitSignal("state_changed", session, playing, paused);
	}

	@Override
	public void finished(int session) {
		emitSignal("finished", session);
	}

	@Override
	public void sleepStopped(int session) {
		emitSignal("sleep_stopped", session);
	}
}
