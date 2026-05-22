<p align="center">
  <img src="./assets/picky-header-logo.svg" alt="Picky" width="240" />
</p>

<p align="center">
  <a href="https://github.com/Jonghakseo/picky/releases/latest">
    <img src="https://img.shields.io/badge/Download-macOS-000?style=for-the-badge&logo=apple&logoColor=white" alt="Download for macOS" />
  </a>
</p>

# Picky

<p align="center">
  <a href="./README.ko.md">한국어</a>
</p>

**A local-first Pi companion for macOS that shows up right where your cursor is.**

Picky lets you call Pi from the middle of whatever you are doing. Hold a shortcut, speak or type, and Picky pops up beside your cursor with the context Pi needs to help: the screen you are looking at, the current URL, selected text, screenshots, and your workspace.

For quick things — translation, small questions, tiny fixes — Picky can answer in place. For work that needs time, it can hand the job to a **Pickle**: another Pi session that keeps running in the Picky Dock while you move on.

Picky stays intentionally lightweight. It follows your cursor, gathers context only for the request you start, and keeps the work local. You can think of Picky as the main agent and Pickles as sub-agents, but the important part is simple: **they are all Pi sessions.**

<p align="center">
  <video src="https://github.com/user-attachments/assets/d3078269-e14a-4f82-89d7-4aac2fb3323a" controls muted playsinline width="720"></video>
</p>

## Why Picky?

Working with an agent often starts with a chore: copy the URL, paste the Slack thread, export the Notion page, take a screenshot, explain where to look, then finally ask the question.

Picky removes that setup work. It gives Pi the context already on your screen, then lets Pi decide whether the request should be handled immediately or handed off to a longer-running Pickle.

Picky helps you:

- **Start from anywhere** — use push-to-talk or quick text input without switching apps.
- **Share the right context** — include the current app, window, selected text, browser page, screenshots, and workspace when you ask.
- **Mark what matters** — point Picky at the part of the screen you mean instead of describing it from scratch.
- **Track longer work** — keep multiple Pickles visible in the Picky Dock with status, logs, artifacts, and follow-up controls.
- **Follow up naturally** — each Pickle is a Pi session, so you can continue the conversation whenever you need.
- **Stay local-first** — Picky runs against your local Pi environment and does not require a backend.

## How it feels to use

```text
Hold shortcut → mark something on screen → ask Picky → watch Pickle work
```

1. Invoke Picky with voice or text.
2. Picky checks what you are looking at — UI, URL, selected text, screenshots, and the area you marked.
3. Pi handles the request directly or starts a Pickle you can monitor, reopen, follow up on, or resume in Pi.

## Highlights

| Feature | What it means |
| --- | --- |
| Cursor-side companion | Voice and text input appear beside your cursor so you can ask for help without breaking your flow. |
| Push-to-talk | Hold a global shortcut and speak naturally. |
| Quick text input | Type a request without leaving your current app. |
| Context capture | Picky gathers context at the moment you send a message, not continuously. |
| Screen marking | Highlight the area you mean so Pi can focus on the right part of the screen. |
| Pickle Dock | Long-running Pi work appears as cards with status, logs, artifacts, and follow-up controls. |
| Pi resume | Switch to the TUI or copy a Pi resume command when you want to continue in a terminal. |
| Local-first design | Picky stays thin; Pi chooses the skills, extensions, MCPs, and tools for the job. |

## Getting started

Picky is currently a macOS app for local Pi users and testers.

You will need:

- macOS 14.2 or newer
- Pi installed locally
- Node.js 22.19.0 or newer available to Picky's launch environment
- A Picky build from the project/test distribution channel, or a local build from source

Picky starts `picky-agentd` with the local `node` executable it finds in `PATH` (including common macOS fallback paths such as `/opt/homebrew/bin` and `/usr/local/bin`). If Node is older than 22.19.0, agentd will not start and Pi handoff features cannot create `agentd-connection.json`.

On first launch, open Picky and follow the setup checklist. Picky will guide you through the required macOS permissions.

For the full walkthrough, see the [User Manual](docs/user-manual.md). Picky can also read that manual through its built-in tools, so you can ask Picky to help with setup too.

## Permissions

Picky asks for macOS permissions that support its local command-center behavior:

| Permission | Used for |
| --- | --- |
| Microphone | Push-to-talk voice capture. |
| Speech Recognition | Apple Speech transcription, if selected. |
| Accessibility | Global shortcuts and interaction helpers. |
| Screen Recording / Screen Content | Screenshots and screen context when you invoke Picky. |

Picky does not continuously capture your screen. Context is gathered only for the flow you request.

## License

See [LICENSE](LICENSE) for licensing details.

- Inspired by [Clicky](https://github.com/farzaa/clicky).
- Inspired by [Pi](https://github.com/earendil-works/pi).
