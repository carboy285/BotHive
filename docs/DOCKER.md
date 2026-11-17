# Run Bothive in Docker (experimental)

This runs the Windows/Electron app headless in a container and serves it through **Web access**, so you open it in a browser. It exists for people who want it on a home server. It has **not been built or run in Docker by the maintainers**; the same start-up sequence (settings written, Electron under a virtual screen, browser login) was checked outside Docker.

## Start

```bash
export OPENGROKBOT_WEB_PASSWORD='choose-a-long-password'   # 10 or more characters
docker compose -f docker/compose.yml up --build
```

Open <http://127.0.0.1:8765>, sign in as `admin` (change with `OPENGROKBOT_WEB_USER`). Chats and settings live in the `opengrokbot-data` volume.

The compose file publishes the port only to this computer. To use it from another device, put it behind your own HTTPS reverse proxy or a private network such as Tailscale. Web access over plain HTTP is for networks you trust, and it refuses clients outside private address ranges.

## AI CLIs

Bothive drives AI CLIs that are installed where it runs, so a container needs its own. The compose file installs Claude Code; change `CLIS` (a space-separated list of npm packages) to add more. Then sign each in once:

```bash
docker compose -f docker/compose.yml exec opengrokbot claude login
```

Your sign-in is stored in the container's home folder, not in the image. Keep it out of any image you share.

## Settings

| Variable | Meaning |
| --- | --- |
| `OPENGROKBOT_WEB_PASSWORD` | Required. 10 or more characters. |
| `OPENGROKBOT_WEB_USER` | Default `admin`. |
| `OPENGROKBOT_PLUGINS` | Comma-separated plugin names to allow (see [PLUGINS.md](PLUGINS.md)). |
| `OPENGROKBOT_DATA_DIR` | Where chats and settings are kept. Default `/data`. |
| `OPENGROKBOT_WEB_ADMIN` | `1` (the compose default) lets the Mac, Windows and iPhone apps change this server's settings. `0` makes it view-and-chat only. |

## Limits

- No microphone, speakers or GUI: voice, desktop notifications and the local browser window do not apply.
- A browser only gets the calls Web access allows. Keys, CLI installs and other settings come from the apps (see below), which sign in with the same username and password.

## Using the server from the apps (10.1.1)

Once it runs, the Mac, Windows and iPhone apps can use it by address instead of through the account relay. Its Bots load in the app itself and you text and talk to them there.

- **Mac and Windows:** Settings → Servers → Add a server, then Connect.
- **iPhone:** Settings → Your computer → Servers (or "Use a server by address" on the first screen).

If the app says the server "is running an older Bothive", the server needs 10.1.1 or later. In the Docker folder run `git pull` and then `docker compose -f docker/compose.yml up --build -d`.

Type the server's address, for example `https://my-box.tailnet-name.ts.net` (from `tailscale serve`) or `http://100.101.102.103:8765`, and sign in with the Web access username and password. Plain `http://` is only accepted for private addresses (Tailscale, home Wi-Fi, local names). Chats and Bots stay on the server.

- On **Mac** the server appears in the main window like another computer on your account; "Back to this Mac" returns.
- On **Windows** the whole window uses the server until you press Back.
- On **iPhone** the app remembers the server until you choose "Back to my account's computer".
- Voice (speaking and listening) happens on the device you are holding; only the text goes to the server.

## Changing the server from another device (10.1.1)

With `OPENGROKBOT_WEB_ADMIN=1` (the default in `docker/compose.yml`), an app connected to the server by its address can do what the server's own settings can, with no terminal:

- **Install an AI CLI.** Settings → the server → AI CLIs → Install. The server downloads it with npm into its own data folder, so it survives restarts. Make default picks which one Bots use.
- **Add an API key.** Paste a key for a provider and Save, or Remove it. Voice keys work the same way.
- **Copy from this device.** "Copy keys and connectors here" on the Mac sends that Mac's keys and connector project to the server in one step. Turn on "Share keys and connectors" on the Mac first.
- **Connectors.** Connect, refresh and remove work from the Windows app. The Mac shows what is connected.

Set `OPENGROKBOT_WEB_ADMIN=0` and run `docker compose -f docker/compose.yml up -d` to turn this off. A browser never gets these powers: only the apps, with the account password.

Signing in to a CLI with a browser link (`claude login`, `codex login`) still has to happen on the server itself. Use an API key from the app when you want to skip that.
