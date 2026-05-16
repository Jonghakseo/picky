<p align="center">
  <img src="./assets/picky-header-logo.svg" alt="Picky" width="240" />
</p>

# Picky

**Your local-first command center for Pi on macOS.**

Picky lets you ask Pi for help from anywhere on your Mac. Hold a shortcut, speak or type what you need, and Picky gives Pi the local context it needs to continue the work in visible, long-running **Pickle** sessions.

Picky is designed to stay lightweight: it appears next to your cursor when you invoke it, captures context only for that request, and keeps your work local.

## Why Picky?

Working with an agent is easier when it can see the same work surface you do — without turning into a cloud dashboard or forcing every task into a chat window.

Picky helps you:

- **Start from anywhere** — use push-to-talk or quick text input without switching apps.
- **Share useful context** — send the current app, window, selected text, browser page, screenshots, and workspace when you ask.
- **Track long-running work** — keep multiple Pickles visible in the Picky dock while they run.
- **Follow up naturally** — reply to an existing Pickle instead of starting over.
- **Stay local-first** — Picky runs against your local Pi environment and does not require a SaaS backend.

## How it feels to use

```text
Hold shortcut → ask Picky → watch the Pickle work
```

1. Invoke Picky with voice or text.
2. Picky gathers the current desktop context.
3. Pi decides how to handle the request and, when needed, starts a Pickle you can monitor, reopen, follow up on, or resume in Pi.

## Highlights

| Feature | What it means |
| --- | --- |
| Menu bar companion | Lightweight status, settings, messages, feedback, and setup from the macOS menu bar. |
| Push-to-talk | Hold a global shortcut and speak naturally. |
| Quick text input | Start a request without leaving your current app. |
| Context capture | Picky captures neutral desktop context only when invoked. |
| Pickle dock | Long-running Pi work appears as visible cards with status, logs, artifacts, and follow-up controls. |
| Pi resume | Open or copy a Pi resume command when you want to continue in a terminal. |
| Local-first design | Picky stays thin; Pi chooses the skills, extensions, MCPs, and tools for the job. |

## Getting started

Picky is currently a macOS app for local Pi users and testers.

You will need:

- macOS 14.2 or newer
- Pi installed locally
- A Picky build from the project/test distribution channel, or a local build from source

On first launch, click the Picky icon in the menu bar and follow the setup checklist. Picky will guide you through the required macOS permissions and Pi runtime check.

For the complete walkthrough, see the [User Manual](docs/user-manual.md).

## Permissions

Picky asks for macOS permissions that support its local command-center behavior:

| Permission | Used for |
| --- | --- |
| Microphone | Push-to-talk voice capture. |
| Speech Recognition | Apple Speech transcription, if selected. |
| Accessibility | Global shortcuts and interaction helpers. |
| Screen Recording / Screen Content | Screenshots and screen context when you invoke Picky. |

Picky does not continuously capture your screen. Context is gathered for the request flow you start.

## Learn more

- [User Manual](docs/user-manual.md) — setup, shortcuts, settings, Pickles, feedback, and daily usage.
- [Architecture](ARCHITECTURE.md) — app/daemon/Pi boundaries and internal data flow.
- [Maintenance Guide](AGENTS.md) — development workflow, build/test commands, and agent instructions.
- [Auto-update Notes](docs/auto-update.md) — Sparkle update behavior and distribution details.
- [Alpha Test Build](docs/alpha-test-build.md) / [Beta Test Build](docs/beta-test-build.md) — packaging and test distribution notes.

## License

See [LICENSE](LICENSE) for licensing details.
