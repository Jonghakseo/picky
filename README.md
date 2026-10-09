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

<p align="center">
  <img src="./assets/screenshots/en/01-hero.jpg" alt="Picky beside a browser window: a Pickle conversation card fixing failing login tests, the Picky Dock listing six Pickles, and a cursor reply saying the work was handed to a Pickle" width="880" />
</p>

Use push-to-talk or quick text input without switching apps. For each request, Picky can gather the active app and window, browser URL, selected text, screenshots, and working directory, depending on permissions and screen-context settings. You can also mark the part of the screen you mean.

Pi can answer directly or hand longer work to a **Pickle**, a separate Pi session. Pickles appear as icons in the Picky Dock; open one to check its progress, logs, and artifacts or send a follow-up.

Picky is the client layer for local Pi sessions and sends no separate telemetry. The models and tools you choose may still use the network.

## A quick tour

<table>
  <tr>
    <td width="50%" valign="top">
      <img src="./assets/screenshots/en/02-voice.jpg" alt="Hold Control + Option and talk: the Picky cursor turns amber and shows the spoken request next to the pointer" />
      <p><b>Hold Control + Option and talk.</b> Release to send. The request carries your screen context.</p>
    </td>
    <td width="50%" valign="top">
      <img src="./assets/screenshots/en/03-annotate.jpg" alt="Answers land right on your screen: original text on a web page is boxed and linked to numbered translation cards" />
      <p><b>Answers on the screen.</b> Picky boxes the original text and pins a numbered translation or explanation beside it.</p>
    </td>
  </tr>
  <tr>
    <td width="50%" valign="top">
      <img src="./assets/screenshots/en/04-pickles.jpg" alt="Hand long work to a Pickle: the Picky Dock shows running, waiting, done, and failed Pickles, including a group" />
      <p><b>Hand long work to a Pickle.</b> Each one runs in its own Pi session. The Dock shows running, waiting, done, and failed at a glance.</p>
    </td>
    <td width="50%" valign="top">
      <img src="./assets/screenshots/en/05-conversation.jpg" alt="Follow the work in one card: a Pickle conversation with replies, tool activity, the current step, and the composer" />
      <p><b>Follow the work in one card.</b> Replies, tool activity, and the current step stay in one thread, with the composer ready for a follow-up.</p>
    </td>
  </tr>
  <tr>
    <td width="50%" valign="top">
      <img src="./assets/screenshots/en/06-quick-input.jpg" alt="Can't talk? Tap Control twice: a Quick Input text box opens beside the cursor" />
      <p><b>Quick Input.</b> Double-tap Control to type instead of talking. The same screen context goes along.</p>
    </td>
    <td width="50%" valign="top">
      <img src="./assets/screenshots/en/07-hub.jpg" alt="Look back on your work in the Hub: the Statistics page with a streak, a daily activity grid, and peak hours" />
      <p><b>The Hub.</b> Work rhythm, AI usage, plugins, web access, and settings in one window.</p>
    </td>
  </tr>
</table>

## Continue from your phone

<p align="center">
  <img src="./assets/screenshots/en/08-phone.jpg" alt="Away from your desk? Pick up on your phone: the phone web app lists Pickles in groups with their status and shows a staging deploy waiting for approval" width="880" />
</p>

The optional phone web app lets you check progress, answer questions, and send instructions to the same Picky and Pickle conversations while away from your Mac. Sessions still run on the Mac; the phone is another way to control them, not a separate agent service.

Enable **Remote access** in the Hub and pair your phone over your own Tailscale or Cloudflare connection. Remote access is off by default, requires Picky to be running and the Mac awake, and uses no Picky-operated server. See [phone setup and usage](docs/user-manual.md#15-remote-access-from-your-phone). For beta builds, use the [release list](https://github.com/Jonghakseo/picky/releases).

## Getting started

You need macOS 14.2 or later and Pi installed locally. Download Picky from [Releases](https://github.com/Jonghakseo/picky/releases/latest) or build it from source.

On first launch, follow the setup checklist for macOS permissions. See the [User Manual](docs/user-manual.md) for setup and usage.

## Permissions

Picky uses Microphone access for voice input, Accessibility for global shortcuts and interactions, and Screen Recording and Screen Content for screenshots and screen context. Apple Speech transcription requests Speech Recognition permission when used. While screen annotations are displayed, Picky may sample the screen to detect changes.

## License

See [LICENSE](LICENSE) for licensing details.

- Inspired by [Clicky](https://github.com/farzaa/clicky).
- Inspired by [Pi](https://github.com/earendil-works/pi).
