<p align="center">
  <img src="./assets/picky-header-logo.svg" alt="Picky" width="240" />
</p>

<p align="center">
  <a href="https://github.com/Jonghakseo/picky/releases/latest">
    <img src="https://img.shields.io/badge/Download-macOS-000?style=for-the-badge&logo=apple&logoColor=white" alt="Download for macOS" />
  </a>
</p>

<p align="center">
  <a href="https://deepwiki.com/Jonghakseo/picky">
    <img src="https://deepwiki.com/badge.svg" alt="Ask DeepWiki" />
  </a>
</p>

# Picky

<p align="center">
  <a href="./README.ko.md">한국어</a>
</p>

**A macOS client for local Pi sessions, right beside your cursor.**

Use push-to-talk or quick text input without switching apps. For each request, Picky can gather the active app and window, browser URL, selected text, screenshots, and working directory, depending on permissions and screen-context settings. You can also mark the part of the screen you mean.

Pi can answer directly or hand longer work to a **Pickle**, a separate Pi session. Pickles appear as icons in the Picky Dock; open one to check its progress, logs, and artifacts or send a follow-up.

Picky is the client layer for local Pi sessions and sends no separate telemetry. The models and tools you choose may still use the network.

## Getting started

You need macOS 14.2 or later and Pi installed locally. Download Picky from [Releases](https://github.com/Jonghakseo/picky/releases/latest) or build it from source.

On first launch, follow the setup checklist for macOS permissions. See the [User Manual](docs/user-manual.md) for setup and usage.

## Permissions

Picky uses Microphone access for voice input, Accessibility for global shortcuts and interactions, and Screen Recording and Screen Content for screenshots and screen context. Apple Speech transcription requests Speech Recognition permission when used. While screen annotations are displayed, Picky may sample the screen to detect changes.

## License

See [LICENSE](LICENSE) for licensing details.

- Inspired by [Clicky](https://github.com/farzaa/clicky).
- Inspired by [Pi](https://github.com/earendil-works/pi).
