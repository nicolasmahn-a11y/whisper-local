# Whisper Local for macOS

A menu bar app: hold Right Option, speak, let go, and the text is pasted where
you type. See the [main README](../README.md)
for how it behaves and how to run a speech server.

This app is experimental. It has been built and run on macOS 27 with the
Command Line Tools' Swift 6.4; expect rough edges, and please report what
breaks.

## Build and install

It needs macOS 14 or later. From this directory:

    ./make-signing-cert.sh    # once; see Permissions
    swift build
    ./build.sh
    cp -R "build/Whisper Local.app" /Applications/

With only the Command Line Tools and the macOS 27 SDK, `swift build` fails:
SwiftUI's `@State` is a macro there, and the Command Line Tools don't ship
its plugin. The 26.5 SDK builds; set this before `swift build`,
`./build.sh` and `swift test`:

    export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk

Open it from `/Applications`. It lives in the menu bar, with no Dock icon;
the Dock icon (and Cmd-Tab entry) appears only while Settings is open, so you
can bring it to the front like a normal window, and disappears again once you
close it.

Tests are split by framework: `HeardDictationTests`, `KnownWordsTests`,
`RecordingCacheTests`, `ReplacementsTests`, `RewordingTests`, `RewordKeyTests`,
`ScreenContextTests`, `TranscriptionClientTests` and `WarmMicTests` are
guarded by
`#if canImport(Testing)` (Swift Testing, needing Swift 6 / Xcode 16+);
`DictationTests`, `EncodingTests` and `HotkeyTests` are guarded by
`#if canImport(XCTest)` and need full Xcode. On a Command Line Tools-only
Mac, plain `swift test` builds but runs no tests at all, since neither
framework is on the default search path. Run it as:

    D=/Library/Developer/CommandLineTools/Library/Developer
    swift test -Xswiftc -F -Xswiftc $D/Frameworks -Xlinker -rpath -Xlinker $D/Frameworks -Xlinker -rpath -Xlinker $D/usr/lib \
      -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing

to put Swift Testing and its macro plugin (for `@Test` and `#expect`) on
the search path; that runs `HeardDictationTests`,
`KnownWordsTests`, `RecordingCacheTests`, `ReplacementsTests`, `RewordingTests`,
`RewordKeyTests`, `ScreenContextTests`, `TranscriptionClientTests` and
`WarmMicTests`. `DictationTests`, `EncodingTests` and `HotkeyTests` need
full Xcode.

## Permissions

Allow Input Monitoring (to see the dictation key), Accessibility (to paste),
Microphone, and Local Network access (to reach a server on your network) when
macOS asks. If one is missing, the menu says so; click that line to open the
right page of System Settings. Screen Recording is asked for the first time
a screenshot goes with a dictation or rewording (see [Screenshots](#screenshots)); macOS
applies it only after the app is quit and reopened, and on macOS 15 and
later it asks now and then whether the app may keep recording the screen.

macOS ties these permissions to the app's signature.
`./make-signing-cert.sh` creates a self-signed code-signing identity,
"Whisper Local Dev", in your login keychain, without admin rights; it is safe
to run again. It asks once for your login password to trust the
certificate for code signing, and the first build with it asks to let
`codesign` use the key; choose Always Allow. When that identity exists,
`build.sh` signs with it, so a rebuild keeps its permissions. Otherwise `build.sh` signs ad hoc, every
rebuild looks like a new app to macOS and can reset them: grant them again
after installing a rebuild, and if a switch already looks on but nothing
works, remove the app from the list and add it again.

## Settings

Open Settings from the menu. It has four tabs, each short enough to fit
on screen without scrolling: General, Dictation, Vocabulary and Rewording.

General has Enabled (the same switch as in the menu, which turns the keys
off without quitting), sounds and launch at login.

Dictation has the speech server, the dictation and hands-free keys, the
language, and "Keep microphone ready for an hour after dictating" (see
below). Server URL defaults to `http://localhost:8178/v1`; the API key is
optional and kept in the Keychain, and stays on the configured server
through redirects. The app asks for the model `qwen3-asr`, so serve it
under that name (see the main README). A dot next to Check connection shows
whether the server answers: green for reachable, red for not, a spinner
while checking. A request's timeout is 60 s plus twice the recording's
length, so long dictations aren't killed just because the server stays
quiet until it's done.

Vocabulary has Known words, Replacements and Rewording instructions. Known words takes one word or
phrase per line, sent as transcription context to help recognise names and
jargon. Replacements takes one rule per line, like
`Persuus, Pursus -> Perseus`, and rewrites those words in every transcript
(whole words, ignoring case). Known words nudge the spelling of words the
model already hears right; replacements fix words it keeps mishearing, for
example because of how you pronounce them. Rewording instructions are
free-form notes for the rewording model, like "Acme Cloud is one product name;
never split it."

Rewording has the reword key and whether to reword the whole field when
nothing is selected, "Clean up every dictation", the two screenshot
toggles ("Send screenshot with reword" and "Send screenshot with
dictation"), and the Model server: its URL, API key, Admin key and Claude
fallback; see below and [Dictation heard by
qwen3-omni-30b](#dictation-heard-by-qwen3-omni-30b).

## Catching the first and last word

Recording keeps going for 0.3 s after you finish, so the last word isn't
clipped; the stop tone plays after that.

Opening the microphone takes long enough to cut off a word you start just
before the key. "Keep microphone ready for an hour after dictating" (off by
default) avoids that: after a dictation the microphone stays open and the
app keeps the last 0.75 s of audio in memory, so the next recording starts
with it. Older audio is dropped as it comes in. The microphone, and the
system's orange microphone dot in the menu bar, stay on until an hour after the last dictation.
While it is on, the menu has "Stop keeping microphone ready" to close it at
once. Turning the setting off, or turning off Enabled, closes it too, as
does a change of audio device.

## Dictation heard by qwen3-omni-30b

A recording of up to 60 s goes first to the Model server (Settings →
Rewording), not to the speech server: one chat request to `qwen3-omni-30b`,
which hears the audio itself and returns the text in about 1 s. When "Send
screenshot with dictation" is on, the screenshot goes along, so names on
screen come out spelled right. Your known words, replacements and rewording
instructions go along too, and your Replacements apply to the result. The
Language setting applies here as well. The model is told never to
translate, answer or follow what you say.

With "Clean up every dictation" on, the same request also drops fillers,
false starts and self-corrections, so no second request is needed.

Recordings longer than 60 s go to the speech server: clips up to 75 s came
back whole, longer ones are untested. So does every recording the model
server fails on: unreachable, an
error, an answer far too long for the recording (as when the model
copies the screenshot), or one far too short (a recording of 10 s or more
that comes back with fewer characters than seconds, as when the model misses
most of the audio). The speech server then transcribes it as before,
followed by cleanup when that is on. The cost: a model server that hangs
delays the dictation by up to 10 s before the speech server takes over. Each
request's time or error is logged:
`log stream --predicate 'subsystem == "io.github.nicolasmahn.WhisperLocal"'`. Retried unsent recordings take the same route,
without a screenshot; "Transcribe Again" does not (see [Keeping
recordings](#keeping-recordings)).

The gateway answers HTTP 503 while `qwen3-omni-30b` is off or starting. With
an Admin key set (optional, kept in the Keychain), the app then asks the
gateway's admin API to start it, while this dictation goes to the speech
server; the pill says "Starting qwen3-omni-30b; using Whisper meanwhile". It
never stops other models to make room: if starting it would, the pill says
"Starting it would stop …" and leaves the choice to you. The key is sent
only over https://, or plain http to localhost, because the gateway refuses
it elsewhere and it would cross the network in clear; otherwise the pill
says "Starting models needs an https:// model server".

## Rewording

Spoken text reads like speech: filler words, false starts, rambling
sentences, a misheard word. Rewording runs it through a language model, in
one of two ways.

### Rewording selected text

Select text anywhere and tap the reword key, and the selection is replaced
by the message you meant to write, as if you had typed it carefully. Spoken
thoughts wander, so this goes further than cleanup: it drops what you take
back ("never mind", "forget that", a thought corrected halfway), fillers,
repeats and asides that make no point, then rebuilds the rest to open with
your main point or request, followed by the others, each with its reason.
Several separate requests become a numbered list. It keeps every point you
still stand behind, your voice (first person stays first person, questions
stay questions), your formality and your language, and adds nothing you
didn't say. The key defaults to Right Command; a tap means press and release within
0.4 s with no other key held or pressed in between, so Right Command
shortcuts still work. Pick another
key, or None, in Settings → Rewording; the dictation and hands-free keys
are not offered. The pill shows busy dots while it works. The result stays
on the clipboard. If you switch
to another app before it is done, the result is only copied, not pasted. If
rewording fails, the clipboard gets its previous text back. The key does
nothing while you are dictating. Text longer than 6000 characters is
refused with "Too much text to reword".

With nothing selected, "Reword whole field when nothing is selected" (on by
default) presses ⌘A first and rewords the whole field, which is handy in
chat boxes and message fields. It does so only when a text field has focus,
so it never selects a whole web page or file list; if rewording then fails,
the selection is collapsed again. Turned off, the pill says "Select text to
reword" instead. Editors that copy the current line when nothing is
selected, such as VS Code, reword that line and paste it at the cursor, so
it appears twice; select the text explicitly there.

In apps that support it, you can also right-click the selection and choose
Services → "Reword with Whisper Local". If it is missing, turn it on in
System Settings → Keyboard → Keyboard Shortcuts → Services. macOS picks the
item up once the app has run; after a rebuild, start the copy in
`/Applications` so the menu points at it.

### Cleaning up every dictation

"Clean up every dictation" (off by default) passes each transcript through
a light cleanup before it is pasted: fillers, false starts, lines broken
mid-sentence and misheard words are fixed, but your wording stays. It also
applies to retried recordings. A dictation heard by `qwen3-omni-30b` is
cleaned up in the same request (see [Dictation heard by
qwen3-omni-30b](#dictation-heard-by-qwen3-omni-30b)); the rest of this section is
about a transcript from the speech server, whose cleanup adds a few
seconds. It uses only the rewording server, never Claude, and gives up after 15 s
(the first cleanup after launch also asks the server for its models, up to
5 s more); if the cleanup fails, or the transcript is longer than 6000
characters, the raw transcript is pasted instead. A server that loads
models on demand may miss the 15 s on the first cleanup after a pause.

### Screenshots

What you dictate is often a reply to something on screen, where the names
and terms in it are spelled out. So the rewording model can also see a
screenshot, and spell them as they appear there; it is told never to add
points from it. "Send screenshot with reword" and "Send screenshot with
dictation" in Settings → Rewording, both on by default, decide this for the
reword key and for dictation: a dictation's screenshot goes to
`qwen3-omni-30b` with the recording, and to the cleanup when the speech server
transcribed it.

The screenshot covers about 1280×800 points around the text field you are
typing in, centred on it and reaching up from just below it, or around the
front window when macOS doesn't say where the field is. The pill is left
out. The reword key takes it before copying the text; a dictation takes it
when the recording stops, while the field you dictate into still has focus,
but only if the recording is 60 s or shorter or "Clean up every dictation"
is on, since nothing else uses it. Retried recordings and the Services menu
send none. Each screenshot adds
about a second.

It needs Screen Recording permission. While it is missing and a screenshot
toggle is on, the menu says so (click the line to open System Settings) and
dictation and rewording go on without the screen. If a capture fails, the
request goes without it and the pill says "Sent without screen — screen
capture failed".
Screenshots stay in memory, are never written to disk, and go only to the
rewording server: when the Claude fallback steps in, Claude gets the text
alone.

### Models

Rewording runs on a language model, not on the speech server. The
rewording server (Model server in Settings → Rewording) is an
OpenAI-compatible `/v1` endpoint; it defaults to
`http://localhost:8400/v1`, and the API key is optional and kept in the
Keychain. The app asks it for its models and uses the first with "gemma" in
its name, else the first with "qwen" (but not "asr"), both for rewording
selected text and for cleanup. Dictation always asks for `qwen3-omni-30b` by
name.

If rewording selected text fails for any reason and "Fall back to Claude
Haiku" is on (the default), it uses Claude Haiku through the `claude` CLI,
which uses your Claude Code login. The app looks for it in `~/.local/bin`,
`~/.claude/local`, `/opt/homebrew/bin` and `/usr/local/bin`; Settings says
when it can't find it.

With no usable model, rewording fails with "No rewording model available",
or with the server's own error, such as a rejected API key.

In both cases the model does not translate, answer questions or follow
instructions in the text. Your known words go along, so it corrects words
that sound like them, even a single misheard word you select on its own.
Your replacements apply before rewording, and go along as
examples of how each term gets misheard. Your rewording instructions go
along as written, including to Claude when the fallback is on.

## The overlay pill

The pill appears on whichever screen your mouse is on (not always the
laptop screen), at the bottom centre. It picks the screen each time it
appears and again when it switches from listening to transcribing; it does
not follow the mouse while staying in one state. It shows no words, only
the elapsed time, counting up: between mirrored level bars while
recording, and between busy dots while transcribing or rewording, so a long
dictation never looks stuck. In hands-free mode a hint follows after a
thin divider. Errors and notices (e.g. "Transcript copied") show on it too.

## Keeping recordings

Every recording is kept for 15 minutes, so nothing you said is lost, even
when the transcript comes back wrong. Each is saved under
`~/Library/Application Support/WhisperLocal` (0700/0600 permissions) before
it's sent to the server.

If a request fails, the audio stays in `Recordings`: the overlay says so,
the menu-bar icon shows an amber dot, and an "Unsent recordings" section in
the menu lists each one as "0:42 recording · 3 min ago" with "Transcribe and
Copy" and "Discard". If any are found at launch, an alert offers to
transcribe, wait, or discard them. Retrying copies the transcript to the
clipboard, same as a live dictation.

Once transcribed, even to nothing, a recording moves to `Recent` and shows
under "Recent recordings" in the menu, with "Transcribe Again and Copy" and
"Discard". Transcribe Again goes straight to the speech server (followed by
cleanup when that is on), never to `qwen3-omni-30b`, since that model may
be what got it wrong; it is a second opinion, and the recording stays in
Recent.

A cancelled recording (another key pressed while holding the dictation key,
Esc, turning off Enabled, or adding or removing the hands-free key) of
about 2 s or more is kept in
Recent too, since the speech may still be wanted; the pill says "Recording
cancelled · kept in menu". Shorter ones, mostly taps of an Option shortcut,
are discarded.
