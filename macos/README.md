# Whisper Local for macOS

A menu bar app that does what the Linux app does: hold Right Option, speak, let
go, and the text is pasted where you type. See the [main README](../README.md)
for how it behaves and how to run a speech server.

This app is experimental. It has been built and run on macOS 26 with the
Command Line Tools' Swift 6.3; expect rough edges, and please report what
breaks.

## Build and install

It needs macOS 14 or later. From this directory:

    swift build
    ./build.sh
    cp -R "build/Whisper Local.app" /Applications/

Open it from `/Applications`. It lives in the menu bar, with no Dock icon;
the Dock icon (and Cmd-Tab entry) appears only while Settings is open, so you
can bring it to the front like a normal window, and disappears again once you
close it.

Tests are split by framework: `KnownWordsTests`, `RecordingCacheTests` and
`TranscriptionClientTests` are guarded by `#if canImport(Testing)` (Swift
Testing, needing Swift 6 / Xcode 16+); `DictationTests`, `EncodingTests` and
`HotkeyTests` are guarded by `#if canImport(XCTest)` and need full Xcode. On
a Command Line Tools-only Mac, plain `swift test` builds but runs no tests
at all, since neither framework is on the default search path. Run it as:

    D=/Library/Developer/CommandLineTools/Library/Developer
    swift test -Xswiftc -F -Xswiftc $D/Frameworks -Xlinker -rpath -Xlinker $D/Frameworks -Xlinker -rpath -Xlinker $D/usr/lib

to put Swift Testing on the search path; that runs `KnownWordsTests`,
`RecordingCacheTests` and `TranscriptionClientTests`. `DictationTests` and
`EncodingTests` also run under `./check-on-linux.sh` (see below), as does
`RecordingCacheTests`; `HotkeyTests` needs full Xcode either way.

## Permissions

Allow Input Monitoring (to see the dictation key), Accessibility (to paste),
Microphone, and Local Network access (to reach a server on your network) when
macOS asks. If one is missing, the menu says so; click that line to open the
right page of System Settings.

`build.sh` signs the app ad hoc, so every rebuild looks like a new app to macOS
and can reset these permissions. Grant them again after installing a rebuild;
if a switch already looks on but nothing works, remove the app from the list
and add it again.

## Settings

Open Settings from the menu; it is grouped into Server, Dictation, Known
words and General.

Server URL defaults to `http://localhost:8000/v1`; the API key is optional
and kept in the Keychain, and stays on the configured server through
redirects. The app asks for the model `qwen3-asr`, so serve it under that
name (see the main README). A dot next to Check connection shows whether the
server answers: green for reachable, red for not, a spinner while checking.
A request's timeout is 60 s plus twice the recording's length, so long
dictations aren't killed just because the server stays quiet until it's done.

Dictation has the dictation and hands-free keys and the language. Known
words takes one word or phrase per line, sent as transcription context to
help recognise names and jargon. General has sounds and launch at login. The
menu keeps the last five transcripts in memory; click one to copy it.

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
