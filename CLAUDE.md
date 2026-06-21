# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository layout

Tchipa is a VCC (virtual credit card) wallet shipped as three deployables that live side-by-side in this repo:

- **`lib/main.dart`** — Flutter Android client (single-file app, ~5,400 lines). Entry point, all models, all screens, all services. Published as `app-release.apk` via GitHub Releases (tag `latest`).
- **`backend/`** — Node.js Express API. Source of truth in this repo; deployed to a VPS at `/var/www/tchipa-api` and run under PM2 as `tchipa-api`. Files here are pushed manually — there is no auto-deploy for the backend.
- **`website/index.html`** — Static landing page at `tchipa.co.uk`. Auto-deployed to GitHub Pages by `.github/workflows/deploy-website.yml` on changes under `website/**`.

Other directories: `scraper/` (legacy AliExpress/Temu Puppeteer scripts, unused by the current product), `server/` (older scraper helpers), `android/`, `web/`, `build/` (Flutter outputs). Top-level `.apk`/`.aab`/`.apks` files are old build artifacts and gitignored — do not commit new ones.

## High-level architecture

The product is a USDT-on-Polygon → PayGate.to VCC pipeline. Two roles interact with the same backend:

1. **Agent** — a **human** USDT reseller in Algeria, not a bot, not a Telegram service. The client pays the agent in **dinars via Barid IMob** (Algerian postal-bank mobile transfer) at the daily exchange rate; the agent then sends the equivalent USDT on Polygon to the address Tchipa generates for the client's VCC order. Coordination (price quote, BaridIMob proof, card delivery confirmation) happens in **direct contact or on Telegram** — that channel is informal and outside this codebase. **The agent uses the Tchipa app itself**, entering Agent mode via Profile → PIN (default `1234`) → `AgentScreen` in `lib/main.dart`. There is no Telegram bot in this project; do not confuse with the unrelated `hermes-agent` project on the same VPS.
2. **Client app** (Flutter): polls the backend by phone number to discover and redeem cards issued for it.

End-to-end flow:

```
Agent  ─► POST /paygate/create-vcc { amount, phone }       (backend/server.js)
backend ─► PayGate.to /crypto/cards/wallet.php             → address_in + redeem_id + exact USDT amount
backend ─► inserts row in agent_orders (SQLite)            phone, redeem_id, status='pending'
backend ─► returns USDT address + QR to agent
client  ─► sends USDT (Polygon) to address_in
forwarder (backend/forwarder.js) ─► watches VPS wallet on Polygon,
            matches incoming USDT to pending_orders via a unique micro-suffix
            (SUFFIX_STEP = 1e-6 USDT), forwards exact amount to PayGate
backend ─► polls PayGate /status.php, fills redeem_link in agent_orders
client app ─► GET /cards/for-phone/:phone (on launch + pull-to-refresh)
            once status=completed and redeem_link present, opens it in WebView
            then POST /cards/mark-delivered to stop re-surfacing the same card
```

Key cross-cutting points to know before changing code:

- **Phone is the join key** between agent and client. `normalizePhone()` in `backend/server.js` (`+` preserved, all non-digits stripped) is used by *both* write and read paths. If you touch one side, touch the other or the join silently breaks.
- **The forwarder is the only writer of outgoing USDT.** It uses a strict `AMOUNT_TOLERANCE` of `5e-6` USDT because uniqueness comes from the per-order micro-suffix, not fuzzy matching. Don't loosen it.
- **`tx.wait()` was replaced with `waitForReceiptWithTimeout()`** in `forwarder.js` (commit `15b2123`) because `tx.wait()` could hang the polling cycle indefinitely after an RPC stall. Keep the bounded receipt poll — don't reintroduce `tx.wait()`.
- **`orders.db` (SQLite) is shared** between `server.js` and `forwarder.js` via `better-sqlite3`. Tables: `orders`, `transactions`, `agent_orders` (server.js side) and `pending_orders`, `processed_txs`, `forwarder_state` (forwarder.js side). Schema migrations are inline `CREATE TABLE IF NOT EXISTS` + ad-hoc `PRAGMA table_info` checks — there is no migration tool.
- **Backend reads env from `/var/www/tchipa-api/.env`** (hardcoded path in both `server.js` line 1 and `forwarder.js` ~line 8). Local dev requires either creating that path or temporarily editing it. `.env.example` shows the required keys: `VPS_WALLET_KEY`, `VPS_WALLET_ADDRESS`, `POLYGON_RPC`.
- **Flutter client talks to the VPS over HTTPS** via `kVpsBase = 'https://api.tchipa.co.uk'` (top of `lib/main.dart`). The hostname resolves to the VPS at `76.13.255.239` and is fronted by nginx as a reverse proxy that terminates TLS (Let's Encrypt) and forwards to the Node.js app on `127.0.0.1:3000` — the Node process itself is **not exposed on the public internet** anymore. iOS App Transport Security and Cloudflare both depend on this; do not bypass it. Setup script and config live in `backend/deploy/` (see `backend/deploy/README.md`). For local dev against a non-prod backend, change this constant.
- **`lib/main.dart` is intentionally one file.** Top of file has models (`VccCard`, `VccOrder`, `VccTx`, `UserProfile`, `AgentOrder`), then `PayGateService` (HTTP client to the VPS), then screens (`HomeScreen`, `TransactionsScreen`, `ProfileScreen`, `AgentScreen` reached via Profile + PIN `1234`, `CardWebViewScreen`). Don't reach for a refactor into multiple files unless asked.

## Commands

### Flutter app

```bash
flutter pub get
flutter analyze                                 # uses analysis_options.yaml (flutter_lints)
flutter test                                    # only test/widget_test.dart exists
flutter run                                     # against an attached device/emulator
flutter build apk --release \
  --dart-define=OPENROUTER_API_KEY=$OPENROUTER_API_KEY
flutter pub run flutter_launcher_icons          # regenerate launcher icons from assets/tchipa_logo.png
```

Release builds are produced by `.github/workflows/build.yml` on every push to `main` and published as the GitHub Release tagged `latest`. Codemagic config in `codemagic.yaml` mirrors this.

### Backend

```bash
cd backend
npm install
node server.js                                  # boots Express on :3000 and starts the forwarder
```

On the VPS the process is managed by PM2 (`pm2 restart tchipa-api`, `pm2 logs tchipa-api`). `ecosystem.config.js` pins `cwd: /var/www/tchipa-api`, so the local checkout is the source you edit and `scp` over — there is no deploy script in the repo for the Node app itself.

HTTPS / nginx side is bootstrapped once via `backend/deploy/setup-https.sh` (idempotent: `apt install nginx certbot`, drop `nginx-api.conf`, run `certbot --nginx`). The Node app stays plain HTTP on `127.0.0.1:3000`; nginx handles TLS for `api.tchipa.co.uk`. Cert renewal is automatic via `certbot.timer`. See `backend/deploy/README.md`.

### Website

Static. Edit `website/index.html`; pushing to `main` triggers the GitHub Pages workflow. `website/CNAME` pins the custom domain `tchipa.co.uk`.

## Conventions worth respecting

- **Hardcoded constants live at the top of their file** (`kVpsBase`, `kExchangeRate`, `kActivationFee`, `kAgentTelegram` in `main.dart`; `PAYGATE_ADDRESS`, `USDT_POLYGON`, `SUFFIX_STEP` etc. in backend files). When a new tunable is introduced, follow that pattern rather than introducing a config module.
- **PayGate routes are namespaced under `/paygate/*`** and admin/debug routes under `/admin/*`. Keep that split — the agent UI scrapes `/admin/*` for diagnostics.
- **Comments in `forwarder.js` explain past bugs** (RPC stalls, `tx.wait` hangs, suffix-based matching). Read them before changing the polling or transfer logic — they encode incidents that already happened.
- **No tests beyond `test/widget_test.dart`.** Don't claim test coverage of a change unless you actually exercise it against a running backend.
