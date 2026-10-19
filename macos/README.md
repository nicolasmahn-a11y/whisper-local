# Whisper Local for macOS

A menu bar app that does what the Linux app does: hold Right Option, speak, let
go, and the text is pasted where you type. See the [main README](../README.md)
for how it behaves and how to run a speech server.

This app is experimental. It has been built and run on macOS 26 with the
Command Line Tools' Swift 6.3; expect rough edges, and please report what
breaks.

## Build and install

It needs macOS 14 or later. From this directory:

    ./make-signing-cert.sh    # once; see Permissions
    swift build
    ./build.sh
    cp -R "build/Whisper Local.app" /Applications/

Open it from `/Applications`. It lives in the menu bar, with no Dock icon;
the Dock icon (and Cmd-Tab entry) appears only while Settings is open, so you
can bring it to the front like a normal window, and disappears again once you
close it.

Tests are split by framework: `KnownWordsTests`, `RecordingCacheTests`,
`ReplacementsTests`, `RewordingTests`, `RewordKeyTests`,
`TranscriptionClientTests` and `WarmMicTests` are guarded by
`#if canImport(Testing)` (Swift Testing, needing Swift 6 / Xcode 16+);
`DictationTests`, `EncodingTests` and `HotkeyTests` are guarded by
`#if canImport(XCTest)` and need full Xcode. On a Command Line Tools-only
Mac, plain `swift test` builds but runs no tests at all, since neither
framework is on the default search path. Run it as:

    D=/Library/Developer/CommandLineTools/Library/Developer
    swift test -Xswiftc -F -Xswiftc $D/Frameworks -Xlinker -rpath -Xlinker $D/Frameworks -Xlinker -rpath -Xlinker $D/usr/lib

to put Swift Testing on the search path; that runs `KnownWordsTests`,
`RecordingCacheTests`, `ReplacementsTests`, `RewordingTests`,
`RewordKeyTests`, `TranscriptionClientTests` and `WarmMicTests`.
`DictationTests` and `EncodingTests` also run under `./check-on-linux.sh` (see
below), as does `RecordingCacheTests`; `HotkeyTests` needs full Xcode either
way.

## Permissions

Allow Input Monitoring (to see the dictation key), Accessibility (to paste),
Microphone, and Local Network access (to reach a server on your network) when
macOS asks. If one is missing, the menu says so; click that line to open the
right page of System Settings.

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

Vocabulary has Known words and Replacements. Known words takes one word or
phrase per line, sent as transcription context to help recognise names and
jargon. Replacements takes one rule per line, like
`Persuus, Pursus -> Perseus`, and rewrites those words in every transcript
(whole words, ignoring case). Known words nudge the spelling of words the
model already hears right; replacements fix words it keeps mishearing, for
example because of how you pronounce them.

Rewording has the reword key and whether to reword the whole field when
nothing is selected, "Clean up every dictation", and the Model server: its
URL, API key and Claude fallback; see below.

The menu keeps the last five transcripts in memory; click one to copy it.

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
are not offered. The pill says "Rewording…" while it works. The result stays
on the clipboard and joins the recent transcripts in the menu. If you switch
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
mid-sentence and misheard words are fixed, but your wording stays. It adds
a few seconds to every dictation, and also applies to retried recordings.
It uses only the rewording server, never Claude, and gives up after 15 s
(the first cleanup after launch also asks the server for its models, up to
5 s more); if the cleanup fails, or the transcript is longer than 6000
characters, the raw transcript is pasted instead. A server that loads
models on demand may miss the 15 s on the first cleanup after a pause.

### Models

Rewording runs on a language model, not on the speech server. The
rewording server (Model server in Settings → Rewording) is an
OpenAI-compatible `/v1` endpoint; it defaults to
`http://localhost:8400/v1`, and the API key is optional and kept in the
Keychain. The app asks it for its models and uses the first with "gemma" in
its name, else the first with "qwen" (but not "asr"), both for rewording
selected text and for cleanup.

If rewording selected text fails for any reason and "Fall back to Claude
Haiku" is on (the default), it uses Claude Haiku through the `claude` CLI,
which uses your Claude Code login. The app looks for it in `~/.local/bin`,
`~/.claude/local`, `/opt/homebrew/bin` and `/usr/local/bin`; Settings says
when it can't find it.

With no usable model, rewording fails with "No rewording model available",
or with the server's own error, such as a rejected API key.

In both cases the model does not translate, answer questions or follow
instructions in the text. Your known words go along, so it keeps those
names and terms as written.

## The overlay pill

The pill appears on whichever screen your mouse is on (not always the
laptop screen), at the bottom centre. It picks the screen each time it
appears and again when it switches from listening to transcribing; it does
not follow the mouse while staying in one state. It says "Listening" while recording and
"Transcribing… m:ss", counting up, while waiting on the server, so a long
dictation never looks stuck. Errors and notices (e.g. "Transcript copied")
show on it too.

## Unsent recordings

Every recording is saved to
`~/Library/Application Support/WhisperLocal/Recordings` before it's sent to
the server (0700/0600 permissions), and deleted once transcription
succeeds. If a request fails, the audio is kept for 15 minutes so nothing
you said is lost: the overlay says so, the menu-bar icon shows an amber dot,
and a new "Unsent recordings" section in the menu lists each one as
"0:42 recording · 3 min ago" with "Transcribe and Copy" and "Discard". If
any are found at launch, an alert offers to transcribe, wait, or discard
them. Retrying copies the transcript to the clipboard, same as a live
dictation.

## Checking changes from Linux

`./check-on-linux.sh` compiles and tests the Foundation-only core in the
official Swift container with Podman. The AppKit and SwiftUI parts need a Mac.
