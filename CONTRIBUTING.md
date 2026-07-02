# Contributing to Spit

Contributions are welcome. Spit is maintained by one person, so please bear with response times.

## Before you start

For anything beyond a small fix, **open an issue first** to discuss the approach. This avoids wasted work on a pull request that doesn't fit the project's direction.

## Workflow

1. Fork the repo and create a branch: `git checkout -b my-feature`
2. Make your changes
3. Verify the build:
   ```bash
   xcodebuild -project VoiceFlow.xcodeproj -scheme VoiceFlow -configuration Debug -destination 'platform=macOS' build
   ```
4. Open a pull request with a clear description of what changed and why

## Bug reports

Include:

- macOS version and Mac model (Apple Silicon required)
- Steps to reproduce
- Relevant lines from `~/Library/Logs/Spit/spit-debug.log` if available

## Project constraints (please read before proposing changes)

- **No third-party dependencies** beyond the Apple SDK and WhisperKit — this is deliberate, not an oversight.
- **Never** change the bundle identifier (`app.getspit`) — it would break Keychain entries and licenses for existing users.
- Everything runs on-device by default. Changes that would send user audio or text off-device need a strong justification and a very explicit opt-in.

## Code style

Follow the existing patterns in the file you're editing. No enforced linter — just match what's around you.
