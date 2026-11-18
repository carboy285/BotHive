# Chat channels (work in progress, not in 10.1.1)

One Bot you choose answers messages that arrive on Telegram, Discord, Slack, SMS, iMessage and phone calls. This page describes the engine on the `claude/channels-wip` branch. There is no Settings screen yet; on a Docker server the channels are set from environment variables.

Nobody is answered until you approve them. A stranger who messages the Bot gets a short code; you enter it under Settings → Channels (or list their ids in `OPENGROKBOT_CHANNELS_APPROVE`).

## iMessage, through Inkbox

[Inkbox](https://inkbox.ai) gives an agent its own iMessage identity, so iMessage works from Windows or a Docker server, not only a Mac, and nothing has to be reachable from the internet. Bothive checks Inkbox's inbox every few seconds and answers in the same conversation.

1. Sign up at inkbox.ai and create an agent with iMessage turned on.
2. Make an API key for that agent in the Inkbox console and give it to Bothive (`OPENGROKBOT_INKBOX_API_KEY`).
3. From your phone, text `connect @your-agent-handle` to Inkbox's router number (Inkbox shows it in its console). After that, your messages reach the Bot. A new person is held until you approve their code.

Inkbox's limits apply: about 100 iMessages a day per agent on the base plan, and a message to someone who has not written back yet must be short with no links or phone numbers. Group chats are ignored. Check Inkbox's pricing page for current plans.

## Other channels

| Channel | Variable(s) |
| --- | --- |
| Telegram | `OPENGROKBOT_TELEGRAM_TOKEN` (from @BotFather) |
| Discord | `OPENGROKBOT_DISCORD_TOKEN` (turn on Message Content Intent) |
| Slack | `OPENGROKBOT_SLACK_BOT_TOKEN` (xoxb-) and `OPENGROKBOT_SLACK_APP_TOKEN` (xapp-, Socket Mode) |
| SMS and calls | `OPENGROKBOT_TWILIO_ACCOUNT_SID`, `OPENGROKBOT_TWILIO_AUTH_TOKEN`, `OPENGROKBOT_TWILIO_NUMBER`, `OPENGROKBOT_OWNER_NUMBER`, `OPENGROKBOT_CALL_PIN`, `OPENGROKBOT_PUBLIC_URL` |
| Which Bot answers | `OPENGROKBOT_CHANNEL_BOT` (a Bot's name; the main Bot by default) |
