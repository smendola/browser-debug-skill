---
name: browser-debug-skill
description: >
  Debug a running in-browser web app via Chrome DevTools Protocol (CDP): stream
  all console output including startup errors, inspect JavaScript variables, and
  reload the page. Use when debugging a web app running in Chrome/Chromium/Edge,
  when you need to see console errors from page load, when you need to inspect
  JS variables in a live tab, or when you need to reload a tab programmatically.
compatibility: >
  Requires Node.js 22+ (built-in WebSocket).
  Browser must be Chrome, Chromium, Edge, Brave, or any Chromium-based browser.
  Firefox is not supported (different protocol).
---

## Overview

Chromium-based browsers expose the Chrome DevTools Protocol (CDP) when launched
with `--remote-debugging-port`. This is the same protocol Electron uses, so the
tooling is identical — the only difference is how you launch the browser.

There are two scripts:

- **`scripts/cdp-watch-startup.js`** — Stream all console output from a tab,
  including errors that fire at page load. Run this first, then navigate to (or
  reload) your app.
- **`scripts/cdp-eval.js`** — One-shot: connect to a running tab, evaluate a
  JS expression, print the result, and exit. Also supports `--reload`.

## Step 1: Launch the browser with the debug port

The `--user-data-dir` flag is **required** when Chrome is already running. Chrome
refuses to open a second instance on the debug port unless it uses a separate
profile directory.

### Helper scripts (recommended)

Two convenience scripts handle killing any running Chrome, optionally cloning a
real profile, launching with CDP on port 9222, and verifying the connection:

- **`scripts/chrome-cdp.sh`** — Linux / macOS (bash)
- **`scripts/chrome-cdp.ps1`** — Windows (PowerShell)

**Why clone your real profile?** A blank debug profile has no login sessions,
cookies, or extensions. Cloning copies Bookmarks, History, Cookies, Preferences,
Local Storage, Extensions, and Local State — so the debug session behaves like
your normal browser. The agent or the user can run the clone step before
starting a debug session.

```bash
# Linux/macOS — clone the "Default" profile then launch
bash scripts/chrome-cdp.sh --clone Default

# Windows — same, PowerShell
pwsh scripts/chrome-cdp.ps1 -Clone Default
```

Other flags:

| Flag | Effect |
|---|---|
| _(none)_ | Launch with whatever is already in `~/.chrome-debug-profile` |
| `--clone <ProfileName>` / `-Clone` | Wipe debug dir, copy named profile, then launch |
| `--reset` / `-Reset` | Wipe debug dir (fresh profile), then launch |

The profile name matches a subdirectory of your Chrome user-data dir
(`~/.config/google-chrome/` on Linux, `%LOCALAPPDATA%\Google\Chrome\User Data\`
on Windows). Common names: `Default`, `Profile 1`, `Profile 2`.

---

### Manual invocation

If you prefer to launch Chrome yourself (or are using Chromium / Edge / Brave):

**Linux (Chrome):**
```bash
google-chrome --remote-debugging-port=9222 \
  --user-data-dir=/tmp/chrome-debug \
  --no-first-run \
  http://localhost:3000
```

**Linux (Chromium):**
```bash
chromium-browser --remote-debugging-port=9222 \
  --user-data-dir=/tmp/chrome-debug \
  --no-first-run \
  http://localhost:3000
```

**macOS:**
```bash
/Applications/Google\ Chrome.app/Contents/MacOS/Google\ Chrome \
  --remote-debugging-port=9222 \
  --user-data-dir=/tmp/chrome-debug \
  --no-first-run \
  http://localhost:3000
```

**Windows:**
```bat
"C:\Program Files\Google\Chrome\Application\chrome.exe" ^
  --remote-debugging-port=9222 ^
  --user-data-dir=C:\temp\chrome-debug ^
  --no-first-run ^
  http://localhost:3000
```

**Edge (any platform):** substitute `msedge` / `Microsoft Edge` for `chrome`.

> **Tip — sandboxed environments:** If Chrome crashes immediately on Linux
> (Docker, CI, some WSL configurations), add `--no-sandbox`. Only use this in
> controlled environments.

## Step 2a: Watch console output (including page-load errors)

Start the watcher **before** navigating to (or reloading) your app so it is
subscribed before your scripts run:

```bash
node scripts/cdp-watch-startup.js
```

If you have multiple tabs open, pass `--url` to pick the right one:

```bash
node scripts/cdp-watch-startup.js --url localhost:3000
```

The script will:

1. Poll `localhost:9222` every 50 ms until a matching page target appears
2. Connect immediately (while the page is still loading)
3. Enable `Console`, `Runtime`, `Log`, and `Page` domains
4. Inject a console buffer via `Page.addScriptToEvaluateOnNewDocument`
5. Reload the page so the buffer is active from literal t0
6. Reconnect and stream all output continuously

**What each output prefix means:**

| Prefix | Source |
|---|---|
| `[error]` / `[warning]` / `[log]` | `console.error/warn/log` calls in page JS |
| `[LOG.error]` | Network/resource failures (`net::ERR_*`, etc.) — these come from the `Log` domain, not `Console`; skipping `Log.enable` would miss them |
| `[EXCEPTION]` | Uncaught JS exceptions |

## Step 2b: Inspect a variable

```bash
node scripts/cdp-eval.js "document.title"
node scripts/cdp-eval.js "JSON.stringify(window.__store?.getState())"
node scripts/cdp-eval.js "performance.getEntriesByType('navigation')[0].loadEventEnd"
```

Use `--url` to target a specific tab when multiple are open:

```bash
node scripts/cdp-eval.js --url localhost:3000 "document.title"
```

## Step 2c: Reload the tab

```bash
node scripts/cdp-eval.js --reload
```

**Verify your reload actually loaded new code.** Add a nonce to your source:

```js
console.log('app version sweet-chocolate');
```

After reload, confirm:

```bash
node scripts/cdp-eval.js "window.__cdpLogs?.find(e=>e.msg.includes('sweet-chocolate'))?.msg"
```

If you do not see the nonce, use `Page.navigate` to the app URL instead of
`Page.reload` — it forces a full navigation that bypasses in-memory caches.

Change the nonce string each time you modify code so you can distinguish
successive reloads from each other.

## Multiple tabs — target selection

Both scripts default to the first non-extension, non-devtools page target. If
you have multiple tabs open, use `--url <substring>` to match by URL:

```bash
node scripts/cdp-watch-startup.js --url localhost:3000
node scripts/cdp-eval.js --url my-app "window.APP_VERSION"
```

The substring is matched against the full tab URL (case-sensitive).

## Port resolution

Both scripts default to port **9222** and apply this logic automatically:

1. Port 9222 is free → use it
2. Port 9222 is occupied and already serving CDP → connect to it
3. Port 9222 is occupied by something else → kill it, reclaim 9222
4. Cannot free 9222 → fall back to 9223

Pass `--port PORT` to override.

## CDP response shape (important gotcha)

`Runtime.evaluate` returns a double-nested result:

```js
// WRONG — this is undefined
msg.result.value

// CORRECT
msg.result.result.value
```

## After a reload, the WebSocket closes

`Page.reload` causes the renderer to navigate. The CDP WebSocket drops.
Always fire reload as fire-and-forget, then close the socket, sleep ~3s,
re-fetch `/json`, and reconnect to the new target.
