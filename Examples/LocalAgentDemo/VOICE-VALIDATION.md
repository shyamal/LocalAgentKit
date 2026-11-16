# Voice workflow acceptance (M4-12)

The iPhone demo's **Voice question** screen runs a short local recording through
transcription, editable review, AgentRuntime, synthesis and playback. It is an
independent, ephemeral single-turn response workflow: no tools or conversation
checkpoint writes are enabled. The existing chat, PDF and receipt screens remain
separate. macOS continues to build the demo but does not show this microphone UI.

## Setup and run

1. Open Voice question. The screen checks English (US) SpeechTranscriber assets.
   If missing, explicitly choose Prepare English speech data and confirm the
   system download. This may use your connection and storage. The SDK recognizer
   still never installs assets; preparation belongs to the host screen.
2. Once ready, choose Record question and grant microphone permission. Capture
   stops automatically after 15 seconds or when you tap Stop recording. A short
   selected audio file or generated synthetic question can also supply input.
3. Review/correct the transcript before Ask and speak. The question is snapshotted
   before execution; later edits do not change the in-flight request. The full
   answer remains readable if synthesis or playback fails.
4. The runtime uses the normal budgeted model and a preselected short-answer
   workflow. Native synthesis generates WAV audio, then native playback uses the
   current media volume/audio route. Replay synthesizes the existing answer
   without generating a new model response.
5. Stop cancels capture, processing or playback; backgrounding/dismissing the
   screen also stops work. Subsequent questions remain usable. The toolbar keeps
   Stop visible while work is active, independently of Form scrolling.

The download step follows Apple's documented [AssetInventory installation flow](https://developer.apple.com/documentation/speech/assetinventory).
A request can complete immediately if shared assets are already present. The
system may retry a failed installation later; the screen rechecks installed state
rather than treating an attempted download as readiness. See Apple's
[downloadAndInstall documentation](https://developer.apple.com/documentation/speech/assetinstallationrequest/downloadandinstall()).
No automatic installation is initiated by opening the voice screen.

Only microphone permission is requested for capture. This uses local
SpeechAnalyzer/SpeechTranscriber, not SFSpeechRecognizer's server authorization;
Apple distinguishes these in [speech permission guidance](https://developer.apple.com/documentation/speech/asking-permission-to-use-speech-recognition).
NSMicrophoneUsageDescription is present in project.yml and the generated app.
The installed AVFAudio/Speech interfaces were also checked before implementation.

## Bounds, ownership and cancellation

- Microphone capture is mono 16 kHz signed 16-bit PCM WAV, up to 15 seconds.
  Imported/recorded encoded input is capped at 2 MiB; the native recognizer allows
  16 decoded seconds to accommodate capture finalization. Transcripts/questions
  are capped at 1,000 characters/4,000 UTF-8 bytes.
- Runtime limits are two decisions, zero tool calls, a 45-second active run and
  30-second model call. The model is asked for two short spoken-friendly sentences.
- Answers over 2,000 characters remain readable with a speech failure; they are
  not silently shortened. Provider audio limits and synthesis timeout remain in
  force. Model refusal is shown and not retried or synthesized automatically.
- The host rejects network-requiring speech providers; AgentRuntime separately
  validates its model configuration under `.never`. Explicit host asset setup is
  outside that run and can download models. This is not OS traffic-capture evidence.
- Recording uses a private temporary directory, removed before transcription.
  The SDK owns/removes its own temporary decoded-input file. Playback consumes
  encoded audio in memory. Raw audio, transcripts and replies are not saved by
  this screen. Asset files managed by the OS intentionally persist independently.
- Controller revisions and load/capture/playback ownership reject late results.
  A cancelled transcription/synthesis cannot restore an old question or start
  delayed playback. Already-running native work may take time to acknowledge
  cancellation; stopping the screen does not promise immediate compute termination.
- Audio-session state is deactivated on cleanup; explicit Stop/background/dismiss
  closes the recorder/player. Native interruption may end a recording early; any
  resulting transcript still requires review before it reaches the agent.

## Verified on the physical iPhone, 2026-11-16

The user explicitly prepared English speech data and confirmed readiness. Then:

- Microphone question "What is two plus two?" → reviewed transcript → agent →
  correct spoken reply was confirmed.
- Replay → Stop during speech → another recorded question working was confirmed.
- Read-only temporary-file metadata showed zero question.wav and recording.audio
  files after the completed turn. No recording, transcript, answer or expense
  contents were exported to verify these results.

This completes M4-12's device path and supplies native successful-transcription
acceptance for M4-05. It does not measure arbitrary speech accuracy, native STT
cancellation timing, or STT energy; M4-09/10 retain those separate checks. English
assets previously absent on this phone are now ready; historical resource results
remain unchanged and their skipped transcription phase is not retroactively filled.

## Automated checks

Eight new portable functions test review-before-model, edited-question delivery,
synthesis/playback ordering, blank-input handling, refusal without retry/speech,
readable playback failure with replay, late recognition/synthesis cancellation,
long-answer bounds and offline provider declarations. The demo package now has
45 registered functions. Capture/device objects stay in iOS-only files excluded
from the portable target; microphone permission and audible playback are verified
through the device checks above, not mocked into a claim of native success.

```bash
swift test --package-path Examples/LocalAgentDemo
```

Developer-only launch routing opens the screen without recording or downloading:

```bash
xcrun devicectl device process launch --device <device-id> --terminate-existing \
  --environment-variables '{"LOCALAGENTKIT_VOICE_DEMO":"1"}' dev.localagentkit.demo.app
```
