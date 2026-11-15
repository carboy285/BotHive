# Bothive privacy policy

Last updated: 15 November 2026. Applies to Bothive 10.0 and later on Mac, Windows and iPhone.

Bothive is a free, open-source app maintained by volunteers (“we” below). This page says what data the apps and the Bothive account service handle, where it goes and how to delete it. The source code is public, so you can check every statement here.

## The short version

- Your Bots, chats, memory, files and AI logins stay on your own computer.
- The Bothive account is only for connecting your iPhone to your computer. It stores your email, your device names and keys, and which Bots you pinned. Messages between your devices are end-to-end encrypted, and the account service deletes them within 90 seconds.
- Bothive has no ads and no analytics, and we don't sell data.
- When you use an AI provider, a voice service or a connected app, what you send goes to that company under *your* account with them, and their privacy policy applies.
- You can delete your account at any time in Settings.

## What stays on your computer

Bots, conversations, Bot memory, files Bots create, settings, your vault, saved logins and API keys stay on the Mac or Windows PC running Bothive:

- Mac: `~/Library/Application Support/OpenGrokBot/` and the macOS Keychain.
- Windows: `%APPDATA%\OpenGrokBot\`, protected with Windows data protection.

(The folders keep the app's old name so upgrades don't lose anything.)

The iPhone app keeps no chat history of its own. It shows your computer's Bots while it is connected.

## The Bothive account

You only need an account to use Bothive from your iPhone or from another computer. It runs on [Supabase](https://supabase.com), which hosts the database and sign-in for us. The account stores:

| Data | Why | Kept until |
|---|---|---|
| Email address, and a password hash or your Google/GitHub sign-in link | To sign you in | You delete the account |
| Each device's ID, name (for example your computer's name), type, public encryption key, when it was last online, and whether it accepts phone connections | So your devices can find each other and check each other's identity | You remove the device or delete the account |
| Which Bots you pinned on each computer | So pins match on all your devices | You delete the account |
| Encrypted messages between your devices | To pass requests and replies between your iPhone and computer | Delivery, and at most 90 seconds |

Messages between devices are encrypted on the sending device with a key only your devices have. The account service can't read them; it only sees their size and which of your devices they are for. When a message arrives, the service may send the receiving device an empty "you have mail" signal so it checks right away.

Supabase processes this data for us. It may store it outside your country. Supabase's own logs (for example IP addresses of requests) are covered by [Supabase's privacy policy](https://supabase.com/privacy).

## Services you choose to use

Bothive works with services you sign up for yourself. When you use one, the data needed for it goes to that company, under your account and their privacy policy:

- **AI command-line tools and providers.** What you write to a Bot, and anything the Bot reads for you, goes to the AI tool or provider you chose (Claude Code, Codex, Gemini CLI, Grok Build or OpenCode, or an API key you added for OpenAI, Anthropic, Google or xAI). Local models (Ollama, LM Studio) stay on your computer.
- **Voice.** By default, Apple's speech recognition runs on your device. If you turn on server recognition, Apple processes the audio. Cloud voices you add (OpenAI, Groq, ElevenLabs) receive the audio or text they work on. The open-source voice runs on your computer after a one-time download of its models from Hugging Face and its runtime from jsDelivr.
- **Connected apps (Composio).** If you add a Composio project key, Composio connects Gmail, Calendar and other apps you authorize, and passes their data to your Bots. Heads-ups read your new mail and calendar through it and send email previews to your AI tool so it can decide what matters.
- **Pictures and video.** Image and video providers you add a key for (Black Forest Labs, Google, OpenAI, Replicate) receive your prompt.
- **The web.** Bots that search or browse visit the sites involved, for example DuckDuckGo for searches, and feeds you ask about.
- **Phone notifications on Mac (optional).** If you turn on ntfy notifications, notification text goes through ntfy.sh to your phone. You can choose to send titles only.
- **Updates.** The apps check GitHub for new releases, so GitHub sees your IP address when they do.

## What we don't do

No ads, no analytics or tracking, no selling or sharing of data for advertising, and no AI training on your data. We don't have access to your chats.

## Your choices and rights

- **Delete your account:** Settings → Account → Delete account. This removes your account, your devices and any messages waiting in the relay straight away. Your Bots and chats stay on your computers; delete them by removing the app's folder listed above.
- **Remove a device:** on your computer, Settings → Computer.
- **Use Bothive without an account:** everything except iPhone access and using another computer works without signing in.

Depending on where you live, you may have the right to access, correct, delete or export your data, or to object to its use. Most of it is on your own devices already. For anything else, ask us (below).

## Children

Bothive isn't meant for children under 13, or under 16 in the EU and UK. Don't create an account for a child.

## Changes

We'll post changes here and on the website with a new date. If a change affects data you've already given us, we'll mention it in the release notes.

## Contact

Open an issue at <https://github.com/carboy285/BotHive/issues>. Issues are public, so don't include personal details there; say you'd like to be contacted privately and we'll reply with a way to do that.
