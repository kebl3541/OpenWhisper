# OpenWhisper

<a href="https://buymeacoffee.com/philosophizer"><img src="https://cdn.buymeacoffee.com/buttons/v2/default-yellow.png" alt="Buy Me A Coffee" height="46"></a>

Speak, and your words appear wherever your cursor is: a chat, an email, a
document, an AI chatbot... anywhere!

OpenWhisper is hands-free dictation for macOS. There are no buttons to
hold and no shortcuts to remember. It listens continuously (until you
mute it), turns speech into text right on your Mac, types it into
whatever you're writing, and in chat apps can even press Return for you.
There are two ways to drive it, and you choose: fully hands-free by
voice, or push-to-talk with a key. See "Two ways to use it" below.

Everything runs on-device with Apple's built-in speech engine. No account,
no cloud, no audio leaving your Mac.

**Developers:** [TECHNICAL.md](TECHNICAL.md) covers building, tuning, and
design; [ARCHITECTURE.md](ARCHITECTURE.md) covers the code.

---

## 1. Installing

**If you downloaded a release (OpenWhisper-vX.X.zip):**

1. Double-click the zip to unpack it. You get `OpenWhisper.app`.
2. Drag `OpenWhisper.app` into your **Applications** folder.
3. First open only: **right-click** the app and choose **Open**, then
   confirm. OpenWhisper isn't in Apple's paid developer program yet, so
   macOS shows an extra warning the first time. This is expected.

If macOS refuses to open it at all, open the **Terminal** app, paste this
line, and press Return:

```
xattr -dr com.apple.quarantine /Applications/OpenWhisper.app
```

Then open the app normally. You only ever do this once.

**Requirements:** a Mac with Apple Silicon (any MacBook/iMac/Mac mini from
2021 or later) running macOS 26 or newer.

## 2. First launch: two permissions

OpenWhisper needs two permissions, and it will ask for both:

1. **Microphone**, so it can hear you. Click **Allow** when asked.
2. **Accessibility**, which is what lets it *type* into other apps. macOS
   sends you to **System Settings → Privacy & Security → Accessibility**;
   turn the switch next to OpenWhisper **on**.

Without the first it can't hear; without the second it hears you but
can't type. If you ever see the menu warn "Grant Accessibility Access",
click it and turn the switch on.

The first launch also downloads Apple's speech model for your language
(a one-time download handled by macOS itself).

## 3. Reading the icon

The waveform icon in the menu bar (the strip at the top of your screen)
tells you at a glance what's happening:

| Icon | Meaning |
|------|---------|
| 🟢 Green waveform | Listening. Speak and it types. |
| 🔴 Red filled waveform | Hearing your voice right now. |
| 🟠 Orange waveform with a slash | **Muted.** Hears only "start listening" and "Hey Claude". |
| Grey waveform with a slash | Microphone fully off. |
| Hourglass / arrow | Starting up or downloading the speech model. |

You may also see a **separate orange microphone icon** in the menu bar.
That one belongs to **macOS**, not OpenWhisper; the system shows it
whenever *any* app is using the microphone. It appears for Zoom and
FaceTime too.

## 4. Dictating

1. Click into any text box so the cursor is blinking there.
2. Speak normally, in sentences.
3. Your words are typed at the cursor as each phrase completes.

Things worth knowing:

- **In Claude and Perplexity**, OpenWhisper presses Return for you about a
  second after you stop talking, making the conversation fully hands-free.
  In every other app it only types; say **"send it"** when you want Return
  pressed.
- **The cursor is everything.** OpenWhisper types "blind" at the cursor.
  If no text box is focused, the words vanish. If the wrong window is
  focused, they go there.
- **Filler sounds are removed.** "Um", "uh", "ehm" never reach the page
  (you can turn this off in Settings).
- **Meetings are safe.** While Zoom, Teams, FaceTime, or Webex is the
  front window, OpenWhisper types nothing at all.
- **Talking to people in the room?** Say **"pause listening"** first,
  otherwise the conversation becomes keystrokes wherever your cursor is.

## 5. Two ways to use it

### Hands-free, by voice (the default)

The app is always listening, and your voice does everything: dictating,
sending ("send it"), deleting ("scratch that"), muting ("pause
listening"), even summoning Claude ("Hey Claude, …"). In chat apps,
Return is pressed for you after a short pause, so a whole conversation
happens without touching the keyboard. This is the mode OpenWhisper was
built for: cooking, pacing the room, resting your wrists. All the
commands are in the next section.

### Push-to-talk, by key

If an always-on microphone isn't your style, three settings turn
OpenWhisper into a classic press-a-key dictation tool:

1. Turn on **Launch muted**, so nothing is typed until you ask.
2. Pick a **toggle hotkey** (⌥ Space, F18, and others). One press
   unmutes, you dictate, one press mutes again.
3. Turn **Auto-send** off and press Return yourself when the text is
   ready.

In this setup the microphone only produces text between your two
keypresses, and nothing is ever sent without you pressing Return. The
menu has clickable equivalents for everything else: mute, unmute, mic
off, copy.

You can mix the modes freely: the voice commands keep working in
push-to-talk mode, and the hotkey keeps working in hands-free mode.

## 6. Voice commands

Say these as their own short phrase (a pause before and after helps).
Add "Claude" in front if you like: "Claude, pause listening."

**Control**

| Say | What happens |
|-----|--------------|
| "pause listening" / "stop dictation" | Mute. Nothing is typed anywhere. Icon turns orange. |
| "start listening" / "resume dictation" | Unmute. |
| "send it" / "send now" / "press enter" | Presses Return immediately, in any app. |
| "scratch that" / "delete that" / "undo" | Deletes the last phrase it typed so you can re-say it. |
| "new line" / "new paragraph" | Line break without sending (Shift+Return). |

**Hands-free Claude**

| Say | What happens |
|-----|--------------|
| "Hey Claude, ⟨your question⟩" | Opens the Claude app, types your question, sends it. Works from anywhere, even while muted. "Hi Claude" and "Okay Claude" work too. |
| "…read it to me" (at the end of a question) | Sends the question, then reads the answer aloud as it arrives. |
| "talk mode on" / "talk mode off" | Read *every* answer aloud automatically. |

**Reading aloud**

| Say | What happens |
|-----|--------------|
| "read it to me" / "read this" | Reads the front window's text aloud, in any app. |
| "stop" / "stop reading" | Stops the voice instantly. |

**Fixing repeated mistakes**

| Say | What happens |
|-----|--------------|
| "replace ⟨wrong⟩ with ⟨right⟩" | From now on, whenever it hears ⟨wrong⟩ it types ⟨right⟩. |
| "forget replacement ⟨wrong⟩" | Removes that rule. |

**Microphone**

| Say | What happens |
|-----|--------------|
| "headphone mic" | Use your headphones' microphone. |
| "mac mic" / "apple mic" | Use the Mac's built-in microphone (recommended). |

## 7. The menu

Click the waveform icon:

- **Mute / Unmute**: same as the voice commands.
- **Turn Mic Off Completely**: releases the microphone entirely (the
  system's orange mic indicator goes out).
- **Auto-send**: whether Return is pressed after you pause.
- **Type into any app**: on means dictate anywhere; off restricts typing
  to your allowed apps (Claude and Perplexity by default).
- **Auto-send in ⟨App⟩**: one click adds or removes the app you're
  currently in from the allowed list.
- **Remove filler words**: the um/uh cleaner.
- **Journal dictations to Markdown…**: optionally save everything you
  dictate into daily text files in a folder you choose.
- **Recent Utterances**: your last 10 phrases; click one to copy it.
- **Settings…**: see below.
- **History…**: appears if you enabled history in Settings.
- **Start at Login**: start OpenWhisper automatically when you log in.

## 8. Settings

Open **Settings…** from the menu. Everything takes effect immediately.

- **Auto-send pause**: how long a silence before your message is sent.
  If messages send while you're still thinking, drag it right.
- **Voice threshold**: how loud a sound must be to count as speech. If
  it types the television, drag right; if it misses your quiet voice,
  drag left.
- **Toggle hotkey**: an optional keyboard shortcut that mutes and
  unmutes, for when pressing a key is quicker than speaking. Pick
  ⌥ Space, ⌃⌥ Space, ⇧⌘ D, F18/F19, or None. Voice control always works
  regardless.
- **Languages**: your main dictation language, and optionally a second
  one. With a second language set, you switch languages just by speaking;
  each sentence goes to the language it was spoken in, no command needed.
  (Off by default because it uses more battery.)
- **Auto-send apps**: the technical list behind "Auto-send in ⟨App⟩".
- **Personal dictionary**: see and edit your "replace X with Y" rules.
- **Launch muted**: start each session silent until you say
  "start listening". Nice if you share your space.
- **Keep searchable history**: remember everything you dictate in a
  local file, searchable from **History…**. Off by default.

## 9. Your privacy

- Speech recognition runs entirely on your Mac. No account, no cloud, no
  network connection.
- OpenWhisper's own log file records only events ("typed 42 characters"),
  never your words.
- Two features write your spoken words to disk, **both off until you turn
  them on**: the journal and the history. Both are plain local files you
  can open, search, and delete yourself.
- One honest caution: the microphone is always on by design, and the "Hey
  Claude" phrase has no voice recognition. Audio playing near your Mac
  (a video, a speakerphone call) could trigger it. If that matters in
  your environment, use **Launch muted** or "Turn Mic Off Completely".

## 10. When something's wrong

**It's not typing anything.**
Check the icon: orange means muted (say "start listening"); grey means the
mic is off (menu → Turn Mic Back On). Green but nothing appears? Make sure
a text box is focused and the cursor is blinking. Still nothing: the menu
will show **⚠️ Grant Accessibility Access** if macOS revoked the typing
permission. Click it and re-enable.

**It sends my message before I've finished the thought.**
Settings → drag **Auto-send pause** right. Or turn **Auto-send** off and
say "send it" when you're ready.

**It types what the TV / my colleagues say.**
Say "pause listening" when you're not dictating, raise the **Voice
threshold**, or enable **Launch muted**.

**It keeps mishearing a word.**
Say "replace ⟨what it typed⟩ with ⟨what you meant⟩". The rule is permanent
and editable later in Settings.

**I can't find the icon.**
A crowded menu bar (especially on Macs with a notch) hides icons. Hold
⌘ and drag other menu bar icons off to make room.

**My headphones made the audio sound terrible.**
Bluetooth headphone mics force phone-quality audio. Say "mac mic" to use
the built-in microphone; your headphones keep playing full-quality sound.

**The words went into the wrong window.**
The cursor moved before the phrase finished. "Scratch that" deletes the
last phrase, but only if you're still in the app it was typed into.

---

*OpenWhisper is open source under the MIT license. Developers: see
[TECHNICAL.md](TECHNICAL.md) and [ARCHITECTURE.md](ARCHITECTURE.md). If it
saves your hands some typing, you can
[buy me a coffee](https://buymeacoffee.com/philosophizer).*
