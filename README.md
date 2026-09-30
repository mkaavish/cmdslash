# CmdSlash

**Tell your Mac what to do.**

CmdSlash is an open-source, native macOS menu-bar app that gives you a global AI command bar for your Mac.

Press **⌘ /** from anywhere, type or speak what you want done, and CmdSlash's AI agent carries it out across your Mac.

> "open my last Figma file"  
> "summarize this page"  
> "add a meeting tomorrow at 3pm"

CmdSlash lives entirely in the menu bar with no Dock icon. The default global hotkey is **⌘ /** and can be remapped from Settings.

## What CmdSlash Can Do

CmdSlash can:

- Launch apps
- Open URLs
- Read and write files
- Run terminal commands
- Read and write your Calendar
- Control a Chromium browser through an extension bridge
  - Navigate
  - Click
  - Extract content
- Read on-screen content through the macOS Accessibility API when an app doesn't have a dedicated integration
- Delegate actual coding tasks to the Claude Code CLI

CmdSlash is designed to keep you in control. Every medium- or high-risk action requires **explicit on-screen confirmation** before it runs.

There is also a local action/audit log, and you can **Pause**, **Cancel**, or **Take Over** at any point.

---

## How It Works

The basic flow is simple:

**Global hotkey → Overlay → Instruction → AI agent → Confirmation when required → Action**

Press **⌘ /** anywhere on macOS to bring up the CmdSlash overlay.

Type an instruction or use voice input. CmdSlash sends the instruction to the configured OpenAI model, determines the actions needed to complete it, and carries those actions out using the appropriate macOS or browser capabilities.

For actions considered medium or high risk, CmdSlash stops and displays an on-screen confirmation before anything is executed.

At any point during a task, you can Pause, Cancel, or Take Over.

---

## Architecture

CmdSlash is a native macOS application built with:

- **Swift**
- **SwiftUI + AppKit**
- **Swift 5.0**
- **Xcode**
- **macOS 26.5+**

CmdSlash runs as an `LSUIElement` menu-bar application, so it does not appear in the Dock.

### AI

CmdSlash is **BYOK — Bring Your Own Key**.

The app talks directly to OpenAI's Chat Completions API using:

`gpt-5.4-mini`

Your OpenAI API key is supplied by you and stored only in the local macOS Keychain under CmdSlash's own service identifier.

There is:

- No CmdSlash account system
- No CmdSlash backend
- No telemetry

Your API key is used only for requests to `api.openai.com`.

Because CmdSlash uses your own API key, **your own OpenAI API usage costs apply**. API usage is billed directly by OpenAI, not CmdSlash.

---

## Build & Setup

### 1. Clone the repo.

```bash
git clone <repo-url>
cd cmdslash
```

### 2. Open CmdSlash.xcodeproj in Xcode.

```bash
open CmdSlash.xcodeproj
```

### 3. Select the CmdSlash target → Signing & Capabilities → change Team to your own Apple ID / personal team (the repo's own team ID won't work for you — this is normal for any cloned Xcode project, not CmdSlash-specific).

### 4. Build and run (Cmd+R).

### 5. On first launch, the companion window opens automatically — paste your OpenAI API key (get one at platform.openai.com) into the API Key field and click Save.

### 6. Press Cmd+/ (or your remapped hotkey) anywhere to open the overlay and try it.

---

## Companion Window

CmdSlash has a second app surface called the **companion window**.

You can open it from the menu-bar icon using:

**Open CmdSlash...**

It also opens automatically on first launch if no API key is stored.

The companion window contains two sections.

### API Key

Paste, replace, or remove your OpenAI API key.

The key is stored locally in the macOS Keychain.

### Settings

From Settings you can:

- Remap the global hotkey by clicking it and pressing a new key combination
- Toggle **Launch CmdSlash at login**

---

## macOS Permissions

CmdSlash requests macOS permissions only for capabilities that require them.

### Microphone

Used for voice input after pressing the global hotkey.

### Speech Recognition

Used on-device to turn spoken instructions into text.

### Calendar — Full Access

Used when you ask CmdSlash to read or create Calendar events.

CmdSlash always asks for confirmation before creating a calendar event.

### Accessibility

Granted through:

**System Settings → Privacy & Security → Accessibility**

This does not use an Info.plist permission prompt.

Accessibility access is needed to read on-screen content in applications without a dedicated integration and for window/app control.

### Screen Recording

Granted through:

**System Settings → Privacy & Security → Screen Recording**

Screen Recording is used as a fallback only when Accessibility-based reading isn't enough.

---

## Chromium Browser Extension

CmdSlash includes an optional Chromium browser extension in a separate folder in the repository.

The extension enables **tab reuse and richer browser control**.

With the extension bridge, CmdSlash can navigate, click, and extract content from the browser.

The main CmdSlash app works without the extension. Without it, URL-based actions fall back to opening new tabs or windows.

---

## Safety & Control

CmdSlash is built around explicit user control.

**Medium- and high-risk actions do not run automatically.** CmdSlash displays an on-screen confirmation and waits for your approval before executing them.

During an active task, you can also:

- **Pause**
- **Cancel**
- **Take Over**

Completed actions are recorded in a **local action/audit log**.

---

## Privacy

CmdSlash does not require an account and does not operate a backend.

Your OpenAI API key is stored only in your local macOS Keychain under CmdSlash's own service identifier.

AI requests are sent directly from CmdSlash to `api.openai.com` using the API key you provide.

CmdSlash includes no telemetry.

---

## Contributing

Contributions are welcome.

1. Fork the repository.
2. Create a branch for your change.
3. Make your changes.
4. Open a pull request describing what you changed and why.

Please keep pull requests focused and avoid bundling unrelated changes together.
