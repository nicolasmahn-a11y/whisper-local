# whisper-local

Hold a key, speak, let go, and the words appear where you are typing, like a
local Wispr Flow. The speech is recognised by Qwen3-ASR on your own machine or
another one on your network, not in someone else's cloud. Recordings up to
60 s go to `qwen3-omni-30b` on your model server first; see
[macos/README.md](macos/README.md#dictation-heard-by-qwen3-omni-30b).

It is a native macOS menu bar app with a small pill that shows the sound level
while you speak. Building, installing, permissions and settings are in
[macos/README.md](macos/README.md). The app is experimental.

## The speech server

whisper-local does not run the model itself. It sends each recording longer
than 60 s, or that `qwen3-omni-30b` fails on, to any OpenAI-compatible
`/v1/audio/transcriptions` endpoint, for example vLLM:

    vllm serve Qwen/Qwen3-ASR-1.7B --served-model-name qwen3-asr

The default server is `http://localhost:8178/v1`. To use another machine, or a
server that wants a key, set the URL and API key in Settings. Leave the API
key field empty for a server without a key. On the author's GPU, 15 s of
speech comes back as text in about a second.

## Using it

- Hold the dictation key (Right Option) and speak. A rising tone means it is
  listening. Let go: a falling tone, and the text is pasted a moment later.
- Presses shorter than 0.3 s are ignored, so a tap sends nothing.
- Pressing any other key while holding cancels the recording, so Option
  shortcuts keep working. Esc cancels too. A cancelled recording of 2 s or
  more stays in the menu for 15 minutes, in case you still want it.
- For hands-free speech, double-tap the dictation key, or choose a separate
  hands-free key in settings (that turns double-tap off). Other keys do not
  cancel it, so you can type or walk away. Tap the key again to finish, or
  press Esc to throw it away.
- The pill shows the sound level while listening, a busy animation while the
  text is being prepared, and the reason when something fails. Failures also
  play two low tones.
- Text arrives in the order it was spoken and stays on the clipboard afterwards.
- The microphone is open only while recording, so the system's microphone
  indicator shows when it listens. You can opt in to keeping it open for an
  hour after dictating; see below.
- Select text and tap Right Command (configurable) to have a language model
  rewrite it as if you had typed it: without what you take back, main point
  first, same voice and language. With nothing selected it rewords the whole
  field. An opt-in setting also lightly cleans up every dictation before
  pasting it. A screenshot around the text field goes along by default, so
  names on screen come out right. See
  [macos/README.md](macos/README.md#rewording).

Opening the microphone takes about 80 ms, which can cut off the first
syllable; start speaking just after the tone. Recording also runs on for
0.3 s after you let go, so the last word isn't clipped, and "Keep microphone
ready for an hour after dictating" (off by default) keeps the microphone open
between dictations, so a word started just before the key is caught too. See
[macos/README.md](macos/README.md#catching-the-first-and-last-word).

## Privacy and security

- Audio goes only to the server URLs you configure, and nowhere else: the
  speech server, and the rewording server for recordings up to 60 s.
- With "Keep microphone ready" on, the microphone records continuously until
  an hour after the last dictation, but only the last 0.75 s is kept, in
  memory, and it is sent only as the start of your next dictation.
- Text you reword goes to the rewording server you configure. If that fails
  and the Claude fallback is on, it goes to Anthropic through the `claude`
  CLI instead. With "Clean up every dictation" on, every transcript also goes
  to the rewording server, but never to Claude. With "Send screenshot with
  reword" or "Send screenshot with dictation" on (the default), a screenshot
  of the area around the text field goes along, to the rewording server only,
  never to Claude; it is never written to disk. The optional admin key, used
  only to start `qwen3-omni-30b` when it is off, is sent only over HTTPS or to
  localhost.
- Over plain HTTP on a network, anyone else on that network can read the audio,
  the transcripts and the API key. Use HTTPS, or keep the server on the same
  machine, if that matters to you.
- Transcripts are kept in memory only and never written to disk. The last one
  stays on the clipboard, replacing what was there.

## License

MIT, see [LICENSE](LICENSE).
