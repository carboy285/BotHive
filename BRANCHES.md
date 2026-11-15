# Branches

Bothive's source is public. Each branch below is a complete, buildable copy of what it says.

| Branch | What's in it | Build |
|---|---|---|
| **`main`** | Everything: the iPhone, Mac and Windows apps, the account service, the website source, docs and release workflows. Releases are built from here. | All of the below |
| **`app/apple`** | The iPhone and Mac apps. They share one Xcode project and about half their code (account, encrypted relay, Bots, voice), so they live together. | Open `GrokBot.xcodeproj`; scheme **GrokBot** for iPhone, **GrokBotMac** for Mac, or `scripts/build-macos.sh` for the DMG |
| **`app/windows`** | The Windows app (Electron). | `npm ci`, then `npm run dist:windows` |
| **`gh-pages`** | The built website, served at <https://carboy285.github.io/bothive/>. Generated from `site/` on `main` by `scripts/build_site.py`. | Nothing to build |

## Where each app lives on `main`

| Folder | App |
|---|---|
| `GrokBot/` | iPhone app, plus code the Mac app shares (`GrokBot/Core`, `GrokBot/Design`, `GrokBot/Voice`) |
| `GrokBotLiveActivity/` | iPhone calls in the Dynamic Island and on the Lock Screen |
| `GrokBotMac/` | Mac app |
| `ComposioBridge/` | Small helper the Mac app ships for connected apps |
| `GrokBotTests/`, `GrokBotMacUITests/` | Apple tests |
| `desktop-windows/` | Windows app |
| `local-voice/` | Source of the open-source voice engine both desktop apps bundle (GPL-3.0-or-later because it includes eSpeak NG; see THIRD_PARTY_NOTICES.md) |
| `supabase/` | The account service: database migrations and their tests |
| `site/` | Website source |

The folders and the Xcode project keep the project's original names (`GrokBot…`) so existing installs keep updating; the apps themselves are called Bothive.

## Shared files

Both app branches carry the account service (`supabase/`), docs, `LICENSE`, `PRIVACY.md`, `TERMS.md`, `THIRD_PARTY_NOTICES.md` and the voice engine source. Rebuilding the voice engine (`scripts/build-local-voice.cjs`) writes into both apps, so do that on `main`.

Work happens on `main` (or a branch off it); `app/apple` and `app/windows` are refreshed from `main` when a release is made. Branches from before 10.0 (`claude/…`, `codex/…`, `feature/…` and others) are kept as history.
