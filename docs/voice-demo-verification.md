# Voice demo (M4-12)

Verified on 2026-11-16 following merged receipt PR #83. The user confirmed the
complete iPhone microphone → reviewed transcript → AgentRuntime → synthesis →
audible reply flow, plus stopping playback and successfully recording another
question. English speech setup was explicitly initiated and confirmed ready in
the app. Full behavior and limits: [voice acceptance](../Examples/LocalAgentDemo/VOICE-VALIDATION.md).

## Architecture

All new code is in LocalAgentDemo. The portable VoiceController uses the existing
SpeechRecognizer, SpeechSynthesizer and local runtime contracts with injectable
play/stop effects. An application-selected response workflow fits the reviewed
question through normal context budgeting. It enables no tools or conversation
persistence. No SDK source, protocols, defaults or dependencies changed.

iOS-only code owns microphone permission, bounded temporary WAV capture, system
asset preparation and in-memory AVAudioPlayer playback. Native objects remain on
the main actor. Speech setup follows Apple AssetInventory's documented explicit
request/download/status flow and never makes the SDK recognizer install assets.
No legacy server speech authorization or cloud speech fallback was added.

Revision/ownership guards stop stale audio-load, transcription, model and synthesis
results from updating a newer turn or starting late playback. The readable answer
survives synthesis/playback failures. Replay does not make another generation call.
Toolbar Stop remains visible during work; background/dismiss cancels and clears
transient capture/playback. Clearing a microphone error lets file/text fallback
show the current operation's result rather than a stale denial message.

## Validation

- Eight new portable voice functions; demo package **45 registered functions**.
  Review gates, ordering, refusal, error recovery/replay, cancellation/late results,
  text/audio bounds and offline speech declarations pass without native assets.
- SDK warning-free build, full **822-function** default suite and offline suite pass.
- Core/Runtime coverage **98.98% (3312/3346)**, unchanged from M4-11. Core 99.59%
  (980/984), Runtime 98.73% (2332/2362); SDK source is unchanged.
- All **80 Python tests**, strict example formatting and layering checks pass.
- Signed iPhone build/installation/launch and macOS demo build pass, with existing
  toolchain AppIntents metadata/orientation warnings only. No signing identity is
  committed. Native frameworks/APIs were verified against installed SDK interfaces
  and Apple's speech setup/permission documentation linked in the guide.
- The user confirmed English setup ready, the correct spoken reply to a microphone
  question, playback Stop, and a working subsequent microphone question.
- Read-only metadata found no lingering question.wav or recording.audio files in
  the app's temporary container after the completed turn. No user audio/transcript
  contents were read/copied by tooling; device outcome evidence is user confirmation.

Logs use `/tmp/lak-m412-`: `demo`, `sdk-build`, `coverage`, `offline`, `python`,
`format`, `layering`, `ios`, `ios-final`, `macos`, `install`, `launch` and `docs`.
The preparation step may download OS-managed language models; no automatic download
or user audio upload was introduced. Future calls can fail if assets are evicted
or the current audio route/model becomes unavailable.

## Separate remaining acceptance

This confirms native STT success for M4-05, not native STT cancellation while the
analyzer is actively processing. M4-09 keeps that acceptance open. M4-10's native
transcription resource phase still needs a new run now that assets are ready.
Historical wired/unplugged reports continue to record that phase as unavailable.
Whole-session energy, multilingual accuracy, noisy environments, route changes,
microphone-denial UI and system-interruption cases need additional testing.
