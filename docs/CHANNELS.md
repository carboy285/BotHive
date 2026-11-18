# Chat channels (10.1.2 Beta)

One Bot you choose answers messages that arrive on Telegram, Discord, Slack, iMessage and SMS, and can phone you. The channels run on a Bothive server: the Docker server, or the Windows app left running. The Mac app does not run them; it sets up a server's channels (open **Settings for \<server\>** while you are viewing it, or use **Settings → Channels** in the Windows app).

## How it stays safe

- **Nobody is answered until you approve them.** A stranger who messages the Bot gets a short code and nothing else. You see their name and the code under Settings → Channels → *Waiting for your OK* and press Approve.
- Approved people are rate limited (30 messages per 10 minutes), and a message can be at most 4,000 characters.
- In a Discord server or a Slack channel the Bot answers only when it is @mentioned. Telegram and iMessage are direct messages only.
- A message from a channel is one Bot turn like any other. The Bot's usual approval prompts still apply, and people on a channel cannot approve purchases, email or deletions on your behalf.
- Tokens are stored on the server (encrypted on Windows, in a private file on Linux) and are never shown again.
- Changing channels from another device needs remote administration on (Docker: `OPENGROKBOT_WEB_ADMIN=1`, the default).

## Choosing the Bot

Pick it under *Which Bot answers* (Docker: `OPENGROKBOT_CHANNEL_BOT`, a Bot's name; the main Bot by default). That Bot is told which channels are connected and which are off or broken, how messages arrive (tagged like `[Telegram · Sam]`), how to write for chat apps, and it gets two tools:

- `channel_send` messages an approved person on a connected channel (20 an hour). Left without a name it goes to whoever wrote last.
- `phone_call` phones your number and opens with what the Bot wants to say (5 an hour).

Texting "call me" on any channel places a call too. Bot-to-Bot messages and heads-up turns can use neither tool.

## Telegram

1. In Telegram, message **@BotFather** and send `/newbot`. Follow the steps.
2. Paste the token it gives you, press Save, then Turn on.
3. Message your new bot, then approve the code it replies with.

## Discord

1. At discord.com/developers/applications make an application and add a **Bot**.
2. Under Bot, turn on **Message Content Intent** and copy the token.
3. Add it to a server with OAuth2 → URL Generator (scope `bot`). It answers direct messages, and in a server when it is @mentioned.

## Slack

1. At api.slack.com/apps make an app from scratch and turn on **Socket Mode**.
2. Make an **App-Level Token** with `connections:write` (starts `xapp-`).
3. Under OAuth & Permissions add `chat:write`, `im:history`, `im:read`, `files:read` (so pictures reach the Bot) and `app_mentions:read`, install it to your workspace and copy the **Bot token** (starts `xoxb-`).
4. Under Event Subscriptions turn on `message.im` and `app_mention`.

## iMessage, through Inkbox

[Inkbox](https://inkbox.ai) gives an agent its own iMessage identity, so this works from Windows or a Docker server and needs no Mac. Bothive checks Inkbox's inbox twice a second, marks your message read and shows the typing bubble at once, then answers in the same conversation.

1. Sign up at inkbox.ai and create an agent with **iMessage turned on**.
2. Make an API key for that agent in the Inkbox console and paste it in (Docker: `OPENGROKBOT_INKBOX_API_KEY`).
3. From your phone, text `connect @your-agent-handle` to Inkbox's router number (the console shows it). Then approve the code Bothive sends back.

Inkbox's limits apply: about 100 iMessages a day per agent on the base plan, and a message to someone who has not written back yet must be short with no links or phone numbers. Group chats are ignored. See Inkbox's pricing page for current plans.

**Who can start a conversation.** On Inkbox's shared number, a person has to text first (`connect @handle`), and the link lapses after a while without messages. The Bot can only start a conversation on its own on a *dedicated line*, which is a paid add-on in the Inkbox console. When the Bot tries to reach you first and Inkbox refuses, the Bot is told "they need to text the Bot once first" and, if the question was urgent, falls back to a phone call. A first message is trimmed to under 160 characters with no links or numbers; the detail follows after you reply.

## Faster replies, photos, and sending several messages

- **Read at once.** The moment an approved person's message arrives the Bot marks it read and shows typing. Strangers get neither.
- **Fast replies on channels** (on by default). Channel messages use the quicker model each CLI has (Haiku, Gemini Flash, Codex at low effort) and ask for one to three plain sentences. Turn it off in Settings → Channels if you want the Bot's full model on every message. A CLI still starts fresh each turn, so expect a few seconds, not an instant answer.
- **Photos and screenshots.** A picture sent on iMessage, Telegram, Discord or Slack is saved to the Bot's Attachments folder and the Bot is told where it is, exactly like a picture attached in the app. Up to three pictures a message, PNG, JPEG, GIF or WebP, judged by their bytes. On the Mac, HEIC photos from an iPhone are converted to JPEG first. Windows and Docker cannot convert HEIC, so the Bot says "send it as a JPEG or a screenshot". Slack needs the `files:read` scope.
- **Bursts become one request.** Messages from one person within about a second (up to four) are read together, so a photo and "add these to my reminders" arrive as one request.
- **Steering.** Send another message while the Bot is working and, by default, the running turn stops and the Bot carries on with your new message in mind (it is told not to redo finished work). Choose **Queue** instead to have it answer after the current turn. The words "stop" or "cancel" only stop. The Mac and Windows chat boxes work the same way.
- **Approval prompts.** Tools that need your OK (like adding reminders) normally ask on the computer's screen. If you are marked Me and the app is in the background, or the request came from a channel, the prompt is also sent to your chat: reply yes or no. Only the person marked Me can answer, and the first answer wins.

## Where replies go

Settings → Channels → **Where replies go**:

- **Reply where I wrote** (default): a text gets a text back, and the reply also shows in the app. A message typed in the app is answered only in the app. Things the Bot does on its own (scheduled tasks, heads-ups) are texted to you on the **Reach me on** channel and shown in the app.
- **Always text me too**: every reply of the channel Bot, including replies to messages typed in the app, is also texted to you.

When the Bot hands part of a request to another Bot, it waits for that Bot's answer and then texts you the result. The first person you approve counts as you (Me) unless you already marked someone, so the Bot can reach you without extra setup.

## Memory

The Bot remembers across every channel and the app:

- A **rolling summary** of what it has been told is refreshed after about every ten new messages by a short background request to the faster model, along with **lasting facts** that are added to its notes (never passwords, codes or one-off details). At 90 notes the pass tidies them down to about 60.
- A **recall** tool searches every message the Bot has had on every channel, including old ones no longer in its context.
- When a Bot's chat passes 9,000 entries, the oldest 2,000 move to an archive file that recall still searches, so a busy Bot never hits the app's limit.
- Give a person a **name** (Rename next to their entry) and the Bot sees the same name on every channel, so Sam on iMessage and Sam on Telegram are one person.

## Phone calls, through Inkbox Voice AI

Turn on iMessage (through Inkbox) and add your own number. Calls are answered and placed by Inkbox's voice assistant, which feels instant and needs no public address.

- Bothive gives the voice assistant the Bot's name, purpose, summary and notes as its instructions (kept under Inkbox's 8,000 characters and refreshed when the Bot's memory changes). It is Inkbox's voice model, not the Bot's own CLI, so it cannot run the Bot's tools during a call. It writes down anything that needs doing; the real Bot picks that up right after the call.
- **Call me**: text "call me", press **Call me now**, or the Bot starts a call with `phone_call`. Only the person marked Me can ask, at most five calls an hour.
- Finished calls come back: after every call the Bot gets a turn with the whole transcript, why the call happened and anything left to do, so it knows what was said and carries on. It texts you a one-line recap, and its summary is refreshed right away so the next call's voice assistant knows about this one. Anything that sends, buys or deletes still needs your OK. If Inkbox can't be read for calls, the reason shows on the iMessage card.
- **Safety.** Inkbox's voice assistant defaults to a mode that can look across the whole identity's contacts, email and messages. In the Inkbox console set the agent to **contact-scoped** access and allow only your own number to call it, so a stranger who finds the number cannot talk to your Bot.

## The Bot reaches out first

Tick **Me** next to your own name (or approve yourself with "This is me"). Then the Bot can contact you without waiting:

- `ask_owner` texts you a question when it needs a decision or a missing detail, then waits. Your next message on that channel is tagged to the Bot as the answer.
- If a question is **urgent** and unanswered after ten minutes (you can change that), Bothive calls you, or texts again if you prefer. No calls during quiet hours (10 pm to 8 am by default).
- It only ever reaches the person marked Me, at most five times an hour and twenty a day. Telegram only lets a bot message someone who has started it once; Discord needs a shared server or earlier direct message; Slack can open a direct message.

## SMS and phone calls, through Twilio

1. Make a Twilio account and buy a phone number. Paste its **Account SID**, **Auth Token** and the number (with country code, like `+15551234567`). Texts to that number reach the Bot.
2. For calls add **your own number**, a **PIN** (4 to 8 digits, for calls *you* make to the Bot) and a **public https address**.
3. Twilio has to reach the Bot over the internet. Bothive serves calls on a separate port (8766) that answers only Twilio: every request must carry Twilio's signature, and nothing else is served there. Put **Tailscale Funnel** in front of that one port, on the computer that runs the server:

   ```bash
   tailscale funnel --bg 8766
   ```

   Paste the https address it prints (like `https://box.tailnet-name.ts.net`). Funnel must be allowed for your tailnet in the Tailscale admin console. Never funnel port 8765; that is Bothive's own login page and settings.
4. Press **Call me now** to test. To take calls *to* your Twilio number, set that number's Voice webhook (POST) to `<your address>/twilio/voice`; the Bot asks for your PIN and only takes calls from your own number.

Calls are turn by turn: Twilio hears you, the Bot answers, Twilio reads the answer, with short holds while the Bot works. Replies are kept to a few spoken sentences. At most five calls an hour.

## Docker

The compose file passes these through (all optional; the screens set the same things):

| Variable | Meaning |
| --- | --- |
| `OPENGROKBOT_CHANNEL_BOT` | Name of the Bot that answers |
| `OPENGROKBOT_CHANNELS_APPROVE` | People approved from the start, like `telegram:123456789,discord:456,imessage:+15551234567!me`. Add `!me` to mark yourself as the owner |
| `OPENGROKBOT_TELEGRAM_TOKEN` | Telegram bot token |
| `OPENGROKBOT_DISCORD_TOKEN` | Discord bot token |
| `OPENGROKBOT_SLACK_BOT_TOKEN`, `OPENGROKBOT_SLACK_APP_TOKEN` | Slack tokens |
| `OPENGROKBOT_INKBOX_API_KEY` | Inkbox API key (iMessage) |
| `OPENGROKBOT_TWILIO_ACCOUNT_SID`, `OPENGROKBOT_TWILIO_AUTH_TOKEN`, `OPENGROKBOT_TWILIO_NUMBER` | Twilio (SMS) |
| `OPENGROKBOT_OWNER_NUMBER`, `OPENGROKBOT_CALL_PIN`, `OPENGROKBOT_PUBLIC_URL`, `OPENGROKBOT_CALL_LANGUAGE` | Calls |

Port 8766 is published to the computer only (`127.0.0.1:8766`), for Tailscale Funnel to reach.

## What is not done

These were tested against fake servers and fake chats, not real Telegram, Discord, Slack, Inkbox or Twilio accounts or a real phone call. Twilio SMS and calls run on a server (Windows or Docker), not on the Mac; the Mac handles Telegram, Discord, Slack and iMessage (through Inkbox) itself, and calls through Inkbox. There is no WhatsApp or email channel yet. Instant answers are not possible with a CLI: expect the read receipt within two seconds and an answer in a few seconds, longer if the Bot uses tools.
