# cmuxterm Optional Sign-In And Zero-Config Mobile Attach Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents are available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an optional account sign-in flow to the Swift macOS cmux app so a signed-in Mac can publish itself and its workspaces for iOS dogfooding, and so iOS can attach directly to that Mac without opening the server config sheet. Unsigned local terminal use must remain unchanged.

**Architecture:** The Mac app opens the web sign-in flow on `cmux.dev`, then receives a native auth callback URL back into the app. The native app stores Stack tokens in a custom token store, validates them through the Stack Auth Swift SDK, defaults to the first team membership, and publishes machine plus workspace state to the existing mobile routes. Zero-config direct attach is part of this plan, so `cmuxd-remote` must grow a direct TLS listener mode and the Mac app must manage its certs, ticket secret, and lifecycle.

**Tech Stack:** SwiftUI, AppKit, StackAuth Swift SDK, local Swift package (`CMUXAuthCore`), URLSession, Hono, Convex-backed mobile routes, Tailscale CLI discovery, Go (`cmuxd-remote`).

**Scope Note:** This plan supersedes the earlier auth-only version. It includes `cmux.dev -> cmux app` callback handling and native zero-config direct terminal attach.

**No-Sleep Rule:** Do not use `sleep`, `Task.sleep`, `DispatchQueue.asyncAfter`, polling loops with arbitrary delays, or similar timing hacks in shipped code for auth callback handling, process startup, publisher coordination, or direct-daemon readiness. Use URL-open callbacks, process pipes, notifications, state observation, and explicit readiness signals.

---

## Testing Strategy

- `cmux` unit tests:
  - `xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux-unit -destination 'platform=macOS' -derivedDataPath /tmp/cmux-auth-unit -only-testing:cmuxTests/AuthCallbackRouterTests -only-testing:cmuxTests/AuthManagerTests -only-testing:cmuxTests/TailscaleStatusProviderTests -only-testing:cmuxTests/WorkspaceSnapshotBuilderTests -only-testing:cmuxTests/MobileHeartbeatPublisherTests -only-testing:cmuxTests/MobileDirectDaemonManagerTests test`
- `cmuxd-remote` tests:
  - `cd /Users/lawrence/fun/cmuxterm-hq/worktrees/feat-cmuxterm-optional-sign-in/daemon/remote && go test ./cmd/cmuxd-remote`
- `manaflow` tests:
  - `cd /Users/lawrence/.config/superpowers/worktrees/manaflow/feat-ios-dogfood-convex/apps/www && bunx vitest run lib/utils/native-app-deeplink.test.ts`
  - `cd /Users/lawrence/.config/superpowers/worktrees/manaflow/feat-ios-dogfood-convex && bun check`
- Tagged build verification:
  - `cd /Users/lawrence/fun/cmuxterm-hq/worktrees/feat-cmuxterm-optional-sign-in && ./scripts/reload.sh --tag auth-mobile`
  - Inspect the built app bundle URL scheme with `plutil` against the built `Info.plist`, not the checked-in plist.
- UI automation:
  - Trigger `test-e2e.yml` for `SettingsAccountUITests` after pushing the branch.
- Manual dogfood:
  - Signed-out launch still behaves exactly like today.
  - Settings shows account state and a browser sign-in button.
  - Browser sign-in returns to the tagged app, not a different installed build.
  - First team membership is selected automatically.
  - The signed-in Mac appears at the top of the iOS terminal home without opening the config sheet.
  - Opening that Mac attaches directly through the daemon ticket path.

---

## Chunk 1: Refresh The Branches And Freeze The New Contract

### File Structure

**cmux repo:** `/Users/lawrence/fun/cmuxterm-hq/worktrees/feat-cmuxterm-optional-sign-in`

- Modify: `GhosttyTabs.xcodeproj/project.pbxproj`
- Modify: `Package.resolved`
- Modify: `Resources/Info.plist`
- Modify: `scripts/reload.sh`
- Create: `cmuxTests/AuthCallbackRouterTests.swift`
- Create: `cmuxTests/AuthManagerTests.swift`
- Create: `cmuxTests/MobileDirectDaemonManagerTests.swift`
- Modify: `daemon/remote/cmd/cmuxd-remote/main_test.go`

**manaflow repo:** `/Users/lawrence/.config/superpowers/worktrees/manaflow/feat-ios-dogfood-convex`

- Create: `apps/www/lib/utils/native-app-deeplink.ts`
- Create: `apps/www/lib/utils/native-app-deeplink.test.ts`
- Modify: `apps/www/app/(home)/handler/after-sign-in/page.tsx`

### Task 1: Rebase And Add Failing Contract Tests

**Files:**
- Test: `cmuxTests/AuthCallbackRouterTests.swift`
- Test: `cmuxTests/AuthManagerTests.swift`
- Test: `cmuxTests/MobileDirectDaemonManagerTests.swift`
- Test: `daemon/remote/cmd/cmuxd-remote/main_test.go`
- Test: `apps/www/lib/utils/native-app-deeplink.test.ts`

- [ ] **Step 1: Rebase both feature branches onto their latest default branches**

Run:

```bash
cd /Users/lawrence/fun/cmuxterm-hq/worktrees/feat-cmuxterm-optional-sign-in && git fetch origin && git rebase origin/main
cd /Users/lawrence/.config/superpowers/worktrees/manaflow/feat-ios-dogfood-convex && git fetch origin && git rebase origin/main
```

Expected:
- Both worktrees are on top of the latest `origin/main`.
- Any conflicts are resolved before writing code.

- [ ] **Step 2: Add failing native auth callback tests**

Cover:
- `cmux://auth-callback?stack_refresh=...&stack_access=...` parses into tokens.
- Tagged callback schemes like `cmux-dev-auth-mobile://auth-callback?...` are accepted.
- Missing tokens or wrong callback paths are rejected.
- Signed-out state does not gate local terminal usage.
- Applying callback tokens marks auth as primed and loads the first team when the Stack client reports memberships.

- [ ] **Step 3: Add failing direct-daemon contract tests**

Cover:
- `cmuxd-remote serve --tls --listen ...` rejects an invalid ticket.
- `cmuxd-remote serve --tls --listen ...` accepts a valid HMAC ticket and answers the JSON handshake.
- The Swift manager builds the right spawn arguments and persists cert plus secret material without using arbitrary waits.

- [ ] **Step 4: Add failing web deeplink allowlist tests**

Cover:
- `cmux://auth-callback` is allowed.
- Tagged dev schemes like `cmux-dev-auth-mobile://auth-callback` are allowed.
- Non-cmux custom schemes are rejected.
- Relative web redirects still work.

- [ ] **Step 5: Run the tests to confirm they fail for the right reasons**

Run:

```bash
cd /Users/lawrence/fun/cmuxterm-hq/worktrees/feat-cmuxterm-optional-sign-in && xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux-unit -destination 'platform=macOS' -derivedDataPath /tmp/cmux-auth-contract -only-testing:cmuxTests/AuthCallbackRouterTests -only-testing:cmuxTests/AuthManagerTests -only-testing:cmuxTests/MobileDirectDaemonManagerTests test
cd /Users/lawrence/fun/cmuxterm-hq/worktrees/feat-cmuxterm-optional-sign-in/daemon/remote && go test ./cmd/cmuxd-remote
cd /Users/lawrence/.config/superpowers/worktrees/manaflow/feat-ios-dogfood-convex/apps/www && bunx vitest run lib/utils/native-app-deeplink.test.ts
```

Expected:
- Swift tests fail because the auth callback router, auth manager hooks, and direct-daemon manager do not exist yet.
- Go tests fail because TLS serve mode and handshake verification do not exist yet.
- Vitest fails because the deeplink helper does not exist yet.

- [ ] **Step 6: Commit the failing tests**

```bash
cd /Users/lawrence/fun/cmuxterm-hq/worktrees/feat-cmuxterm-optional-sign-in
git add cmuxTests/AuthCallbackRouterTests.swift cmuxTests/AuthManagerTests.swift cmuxTests/MobileDirectDaemonManagerTests.swift daemon/remote/cmd/cmuxd-remote/main_test.go
git commit -m "test: define native auth and direct attach contract"

cd /Users/lawrence/.config/superpowers/worktrees/manaflow/feat-ios-dogfood-convex
git add apps/www/lib/utils/native-app-deeplink.test.ts
git commit -m "test: define cmux deeplink contract"
```

---

## Chunk 2: Teach `cmux.dev` To Return To cmuxterm

### File Structure

**manaflow repo:** `/Users/lawrence/.config/superpowers/worktrees/manaflow/feat-ios-dogfood-convex`

- Create: `apps/www/lib/utils/native-app-deeplink.ts`
- Create: `apps/www/lib/utils/native-app-deeplink.test.ts`
- Modify: `apps/www/app/(home)/handler/after-sign-in/page.tsx`

### Task 2: Generalize The After-Sign-In Page For cmuxterm

**Files:**
- Create: `apps/www/lib/utils/native-app-deeplink.ts`
- Modify: `apps/www/app/(home)/handler/after-sign-in/page.tsx`
- Test: `apps/www/lib/utils/native-app-deeplink.test.ts`

- [ ] **Step 1: Add a small helper that validates native cmux callback URLs**

Rules:
- allow `cmux://auth-callback`
- allow tagged debug schemes matching the cmux debug pattern
- reject non-cmux schemes
- keep relative web redirects unchanged

- [ ] **Step 2: Update the after-sign-in page to use the helper**

Implementation rules:
- stop hardcoding `manaflow://`
- keep the existing “fresh session before deeplink” behavior
- keep relative web redirects working
- only open native links that pass the helper

- [ ] **Step 3: Run the web tests**

Run:

```bash
cd /Users/lawrence/.config/superpowers/worktrees/manaflow/feat-ios-dogfood-convex/apps/www && bunx vitest run lib/utils/native-app-deeplink.test.ts
cd /Users/lawrence/.config/superpowers/worktrees/manaflow/feat-ios-dogfood-convex && bun check
```

Expected: PASS.

- [ ] **Step 4: Commit**

```bash
cd /Users/lawrence/.config/superpowers/worktrees/manaflow/feat-ios-dogfood-convex
git add apps/www/lib/utils/native-app-deeplink.ts apps/www/lib/utils/native-app-deeplink.test.ts 'apps/www/app/(home)/handler/after-sign-in/page.tsx'
git commit -m "auth: allow cmux native callback deeplinks"
```

---

## Chunk 3: Add Native Auth Foundation And Settings UI In cmuxterm

### File Structure

**cmux repo:** `/Users/lawrence/fun/cmuxterm-hq/worktrees/feat-cmuxterm-optional-sign-in`

- Modify: `GhosttyTabs.xcodeproj/project.pbxproj`
- Modify: `Package.resolved`
- Modify: `Resources/Info.plist`
- Modify: `Resources/Localizable.xcstrings`
- Modify: `scripts/reload.sh`
- Modify: `Sources/AppDelegate.swift`
- Modify: `Sources/cmuxApp.swift`
- Create: `Packages/CMUXAuthCore/Package.swift`
- Create: `Packages/CMUXAuthCore/Sources/CMUXAuthCore/CMUXAuthConfig.swift`
- Create: `Packages/CMUXAuthCore/Sources/CMUXAuthCore/CMUXAuthState.swift`
- Create: `Packages/CMUXAuthCore/Sources/CMUXAuthCore/CMUXAuthUser.swift`
- Create: `Packages/CMUXAuthCore/Sources/CMUXAuthCore/CMUXAuthCallbackPayload.swift`
- Create: `Packages/CMUXAuthCore/Tests/CMUXAuthCoreTests/CMUXAuthStateTests.swift`
- Create: `Sources/Auth/AuthEnvironment.swift`
- Create: `Sources/Auth/StackAuthApp.swift`
- Create: `Sources/Auth/StackAuthTokenStore.swift`
- Create: `Sources/Auth/AuthCallbackRouter.swift`
- Create: `Sources/Auth/AuthSettingsStore.swift`
- Create: `Sources/Auth/AuthManager.swift`
- Create: `Sources/Auth/AccountSettingsView.swift`

### Task 3: Implement Browser-Based Optional Sign-In

**Files:**
- Create: `Packages/CMUXAuthCore/...`
- Create: `Sources/Auth/...`
- Modify: `Sources/AppDelegate.swift`
- Modify: `Sources/cmuxApp.swift`
- Modify: `Resources/Info.plist`
- Modify: `scripts/reload.sh`
- Test: `cmuxTests/AuthCallbackRouterTests.swift`
- Test: `cmuxTests/AuthManagerTests.swift`

- [ ] **Step 1: Port the minimal shared auth-core types**

Include:
- auth config
- auth state
- auth user
- callback payload parser

Do not put UI or network code into `CMUXAuthCore`.

- [ ] **Step 2: Add StackAuth to the Xcode project and build a custom token store**

Implementation rules:
- use the Stack Auth Swift prerelease package
- use a custom token store backed by Keychain-compatible persistence, not browser cookies
- auth manager must be able to seed tokens from the native callback URL
- team list comes from `StackClientApp.getUser()` plus `CurrentUser.listTeams()`

- [ ] **Step 3: Add a callback scheme build setting and tagged-build override**

Rules:
- release default: `cmux`
- debug default: `cmux-dev`
- tagged reloads: `cmux-dev-<tag-slug>`
- `Resources/Info.plist` reads the scheme from a build setting
- `scripts/reload.sh` passes the override so the browser returns to the tagged build you launched

- [ ] **Step 4: Route native callback URLs through AppDelegate**

Implementation rules:
- `application(_:open:)` must distinguish auth callback URLs from folder opens
- auth callbacks go to `AuthManager`
- non-auth URLs keep existing folder-open behavior

- [ ] **Step 5: Add an Account section to Settings**

Requirements:
- signed-out state shows a “Sign In in Browser” button
- signed-in state shows email plus selected team and a sign-out button
- local terminal behavior remains available when signed out
- all new user-facing strings are localized in English and Japanese

- [ ] **Step 6: Run unit tests and built-app verification**

Run:

```bash
cd /Users/lawrence/fun/cmuxterm-hq/worktrees/feat-cmuxterm-optional-sign-in && swift test --package-path Packages/CMUXAuthCore
cd /Users/lawrence/fun/cmuxterm-hq/worktrees/feat-cmuxterm-optional-sign-in && xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux-unit -destination 'platform=macOS' -derivedDataPath /tmp/cmux-auth-foundation -only-testing:cmuxTests/AuthCallbackRouterTests -only-testing:cmuxTests/AuthManagerTests test
cd /Users/lawrence/fun/cmuxterm-hq/worktrees/feat-cmuxterm-optional-sign-in && ./scripts/reload.sh --tag auth-mobile
plutil -p "$HOME/Library/Developer/Xcode/DerivedData/cmux-auth-mobile/Build/Products/Debug/cmux DEV auth-mobile.app/Contents/Info.plist"
```

Expected:
- package tests pass
- unit tests pass
- the built app bundle advertises the tagged auth callback scheme

- [ ] **Step 7: Commit**

```bash
cd /Users/lawrence/fun/cmuxterm-hq/worktrees/feat-cmuxterm-optional-sign-in
git add GhosttyTabs.xcodeproj/project.pbxproj Package.resolved Resources/Info.plist Resources/Localizable.xcstrings scripts/reload.sh Packages/CMUXAuthCore Sources/Auth Sources/AppDelegate.swift Sources/cmuxApp.swift
git commit -m "auth: add optional browser sign-in for cmuxterm"
```

---

## Chunk 4: Publish Signed-In Machine And Workspace State

### File Structure

**cmux repo:** `/Users/lawrence/fun/cmuxterm-hq/worktrees/feat-cmuxterm-optional-sign-in`

- Create: `Sources/MobilePresence/MachineIdentityStore.swift`
- Create: `Sources/MobilePresence/TailscaleStatusProvider.swift`
- Create: `Sources/MobilePresence/MachineSessionClient.swift`
- Create: `Sources/MobilePresence/WorkspaceSnapshotBuilder.swift`
- Create: `Sources/MobilePresence/MobileHeartbeatPublisher.swift`
- Create: `Sources/MobilePresence/MobilePresenceCoordinator.swift`
- Modify: `Sources/TabManager.swift`
- Modify: `Sources/Workspace.swift`
- Modify: `Sources/AppDelegate.swift`
- Test: `cmuxTests/TailscaleStatusProviderTests.swift`
- Test: `cmuxTests/WorkspaceSnapshotBuilderTests.swift`
- Test: `cmuxTests/MobileHeartbeatPublisherTests.swift`

### Task 4: Make A Signed-In Mac Publish Itself Automatically

**Files:**
- Create: `Sources/MobilePresence/...`
- Modify: `Sources/TabManager.swift`
- Modify: `Sources/Workspace.swift`
- Modify: `Sources/AppDelegate.swift`

- [ ] **Step 1: Add a stable machine identity and Tailscale status provider**

Rules:
- machine identity persists locally
- display name defaults to the Mac hostname
- Tailscale data comes from `tailscale status --json`
- missing Tailscale is not fatal, it just disables remote presence

- [ ] **Step 2: Build workspace snapshots from live cmux state**

Each workspace snapshot must include:
- workspace id
- title
- preview
- phase
- tmux session name
- latest activity timestamps and sequence

- [ ] **Step 3: Add the authenticated machine-session client and heartbeat publisher**

Rules:
- use the signed-in Stack access token as a bearer token
- default to the first team membership
- persist the chosen team in settings so the user can change it later
- signed-out state is a no-op

- [ ] **Step 4: Add a coordinator that reacts to real app signals**

Use:
- auth state changes
- team selection changes
- workspace open/close/update notifications
- app active/inactive lifecycle

Do not use arbitrary delays or polling loops.

- [ ] **Step 5: Run unit tests**

Run:

```bash
cd /Users/lawrence/fun/cmuxterm-hq/worktrees/feat-cmuxterm-optional-sign-in && xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux-unit -destination 'platform=macOS' -derivedDataPath /tmp/cmux-mobile-presence -only-testing:cmuxTests/TailscaleStatusProviderTests -only-testing:cmuxTests/WorkspaceSnapshotBuilderTests -only-testing:cmuxTests/MobileHeartbeatPublisherTests test
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
cd /Users/lawrence/fun/cmuxterm-hq/worktrees/feat-cmuxterm-optional-sign-in
git add Sources/MobilePresence Sources/TabManager.swift Sources/Workspace.swift Sources/AppDelegate.swift
git commit -m "mobile: publish signed-in machine and workspace state"
```

---

## Chunk 5: Add Native Zero-Config Direct Attach

### File Structure

**cmux repo:** `/Users/lawrence/fun/cmuxterm-hq/worktrees/feat-cmuxterm-optional-sign-in`

- Modify: `daemon/remote/cmd/cmuxd-remote/main.go`
- Modify: `daemon/remote/cmd/cmuxd-remote/main_test.go`
- Create: `Sources/DirectAttach/DirectDaemonCertificateStore.swift`
- Create: `Sources/DirectAttach/MobileDirectDaemonManager.swift`
- Modify: `Sources/MobilePresence/MobileHeartbeatPublisher.swift`
- Modify: `Sources/Workspace.swift`
- Test: `cmuxTests/MobileDirectDaemonManagerTests.swift`

### Task 5: Extend `cmuxd-remote` And Publish `directConnect`

**Files:**
- Modify: `daemon/remote/cmd/cmuxd-remote/main.go`
- Create: `Sources/DirectAttach/...`
- Modify: `Sources/MobilePresence/MobileHeartbeatPublisher.swift`
- Modify: `Sources/Workspace.swift`

- [ ] **Step 1: Add TLS listener mode to `cmuxd-remote`**

New CLI shape:

```text
cmuxd-remote serve --tls --listen 0.0.0.0:9443 --server-id <machine-id> --ticket-secret <hex> --cert-file <path> --key-file <path>
```

Protocol rules:
- accept a TLS socket
- read one JSON line with `{ "ticket": "..." }`
- verify HMAC signature, expiry, server id, and capability set
- reply with JSON `{ "ok": true }` or `{ "ok": false, "error": { ... } }`
- after a successful handshake, reuse the existing line-oriented RPC server

- [ ] **Step 2: Add a Swift direct-daemon manager**

Responsibilities:
- derive hostnames and Tailscale IPs
- generate and persist a self-signed cert plus ticket secret
- compute SHA-256 certificate pins
- spawn `cmuxd-remote`
- wait for an explicit readiness signal from the process pipe, not `sleep`
- restart only when machine hosts or binary path change

- [ ] **Step 3: Feed `directConnect` into the heartbeat payload**

The heartbeat payload must include:
- `directPort`
- `directTlsPins`
- `ticketSecret`

Only publish this when the daemon is healthy and the machine has usable Tailscale reachability.

- [ ] **Step 4: Run Go and Swift tests**

Run:

```bash
cd /Users/lawrence/fun/cmuxterm-hq/worktrees/feat-cmuxterm-optional-sign-in/daemon/remote && go test ./cmd/cmuxd-remote
cd /Users/lawrence/fun/cmuxterm-hq/worktrees/feat-cmuxterm-optional-sign-in && xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux-unit -destination 'platform=macOS' -derivedDataPath /tmp/cmux-direct-daemon -only-testing:cmuxTests/MobileDirectDaemonManagerTests -only-testing:cmuxTests/MobileHeartbeatPublisherTests test
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd /Users/lawrence/fun/cmuxterm-hq/worktrees/feat-cmuxterm-optional-sign-in
git add daemon/remote/cmd/cmuxd-remote/main.go daemon/remote/cmd/cmuxd-remote/main_test.go Sources/DirectAttach Sources/MobilePresence/MobileHeartbeatPublisher.swift Sources/Workspace.swift
git commit -m "mobile: add zero-config direct daemon attach"
```

---

## Chunk 6: Verify The Dogfood Path End To End

### Task 6: Run Final Verification And Prepare For Review

**Files:**
- Modify as needed based on verification failures
- Test: `cmuxUITests/SettingsAccountUITests.swift` if the UI coverage does not exist yet

- [ ] **Step 1: Run the full local verification set**

Run:

```bash
cd /Users/lawrence/.config/superpowers/worktrees/manaflow/feat-ios-dogfood-convex/apps/www && bunx vitest run lib/utils/native-app-deeplink.test.ts
cd /Users/lawrence/.config/superpowers/worktrees/manaflow/feat-ios-dogfood-convex && bun check
cd /Users/lawrence/fun/cmuxterm-hq/worktrees/feat-cmuxterm-optional-sign-in/daemon/remote && go test ./cmd/cmuxd-remote
cd /Users/lawrence/fun/cmuxterm-hq/worktrees/feat-cmuxterm-optional-sign-in && xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux-unit -destination 'platform=macOS' -derivedDataPath /tmp/cmux-auth-final -only-testing:cmuxTests/AuthCallbackRouterTests -only-testing:cmuxTests/AuthManagerTests -only-testing:cmuxTests/TailscaleStatusProviderTests -only-testing:cmuxTests/WorkspaceSnapshotBuilderTests -only-testing:cmuxTests/MobileHeartbeatPublisherTests -only-testing:cmuxTests/MobileDirectDaemonManagerTests test
```

Expected: PASS.

- [ ] **Step 2: Add or update a focused UI automation case**

Cover:
- opening Settings
- tapping “Sign In in Browser”
- handling a synthetic auth callback
- showing signed-in account state

Then push the branch and run:

```bash
gh workflow run test-e2e.yml --repo manaflow-ai/cmux -f ref=feat-cmuxterm-optional-sign-in -f test_filter="SettingsAccountUITests" -f record_video=true
```

- [ ] **Step 3: Run a tagged build and manual dogfood**

Run:

```bash
cd /Users/lawrence/fun/cmuxterm-hq/worktrees/feat-cmuxterm-optional-sign-in && ./scripts/reload.sh --tag auth-mobile
```

Manual checks:
- signed out, local workspace behavior is unchanged
- sign in opens `cmux.dev`
- finishing sign in returns to the tagged app
- the signed-in Mac shows up in the iOS terminal home
- tapping it opens a workspace directly, without the config sheet

- [ ] **Step 4: Fix anything the verification found, rerun the affected tests, and commit**

Use focused fix commits. If a regression test was added for a bug uncovered here, keep the test-only commit before the fix commit.

- [ ] **Step 5: Complete the branch the normal way**

After all tests and dogfood checks pass:
- announce that you are using `finishing-a-development-branch`
- follow that skill
- do not merge to `main` unless the user explicitly asks in that turn

## Follow-on Note

The signed-in Mac path from this plan now feeds the mobile HTTP boundary documented in `2026-03-18-ios-convex-grdb-cache-boundary.md`. The Mac app still publishes machine session and heartbeat data through server routes, while the iOS app boots from GRDB first and only uses Convex behind the dedicated live-sync seam.
