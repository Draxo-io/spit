# Security Policy

Spit processes voice audio and injects text into other applications on your Mac. We take security seriously.

## Reporting a Vulnerability

If you find a security vulnerability, please report it privately — do not open a public GitHub issue.

Email **rafa@getspit.app** with:

- A description of the vulnerability and its potential impact
- Steps to reproduce
- Affected version (see Settings → About)

You should receive a response within 5 business days. We'll keep you updated as we work on a fix, and credit you in the release notes (unless you'd prefer to stay anonymous).

## Scope

Spit is a native macOS app with no backend servers involved in normal operation — audio never leaves your device. Relevant areas for security review:

- Accessibility API usage (`AXUIElement`) and text injection
- Microphone/audio handling and App Sandbox entitlements
- Keychain usage (BYOK API keys, if configured)
- WhisperKit model loading and inference

## Supported Versions

Only the latest release is supported. Please update to the newest version before reporting an issue that may already be fixed.
