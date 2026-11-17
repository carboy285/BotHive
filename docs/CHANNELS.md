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
3. Under OAuth & Permissions add `chat:write`, `im:history`, `im:read` and `app_mentions:read`, install it to your workspace and copy the **Bot token** (starts `xoxb-`).
4. Under Event Subscriptions turn on `message.im` and `app_mention`.

## iMessage, through Inkbox

[Inkbox](https://inkbox.ai) gives an agent its own iMessage identity, so this works from Windows or a Docker server and needs no Mac. Bothive checks Inkbox's inbox every few seconds and answers in the same conversation.

1. Sign up at inkbox.ai and create an agent with **iMessage turned on**.
2. Make an API key for that agent in the Inkbox console and paste it in (Docker: `OPENGROKBOT_INKBOX_API_KEY`).
3. From your phone, text `connect @your-agent-handle` to Inkbox's router number (the console shows it). Then approve the code Bothive sends back.

Inkbox's limits apply: about 100 iMessages a day per agent on the base plan, and a message to someone who has not written back yet must be short with no links or phone numbers. Group chats are ignored. See Inkbox's pricing page for current plans.

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
| `OPENGROKBOT_CHANNELS_APPROVE` | People approved from the start, like `telegram:123456789,discord:456,sms:+15551234567` |
| `OPENGROKBOT_TELEGRAM_TOKEN` | Telegram bot token |
| `OPENGROKBOT_DISCORD_TOKEN` | Discord bot token |
| `OPENGROKBOT_SLACK_BOT_TOKEN`, `OPENGROKBOT_SLACK_APP_TOKEN` | Slack tokens |
| `OPENGROKBOT_INKBOX_API_KEY` | Inkbox API key (iMessage) |
| `OPENGROKBOT_TWILIO_ACCOUNT_SID`, `OPENGROKBOT_TWILIO_AUTH_TOKEN`, `OPENGROKBOT_TWILIO_NUMBER` | Twilio (SMS) |
| `OPENGROKBOT_OWNER_NUMBER`, `OPENGROKBOT_CALL_PIN`, `OPENGROKBOT_PUBLIC_URL`, `OPENGROKBOT_CALL_LANGUAGE` | Calls |

Port 8766 is published to the computer only (`127.0.0.1:8766`), for Tailscale Funnel to reach.

## What is not done

These were tested against fake servers and fake chats, not real Telegram, Discord, Slack, Inkbox or Twilio accounts or a real phone call. The Mac and iPhone apps do not run channels themselves, and there is no WhatsApp or email channel yet.
