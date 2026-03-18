# Rivet Mobile Workspace State Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the Convex-backed mobile workspace and machine state path with a cmux-owned Rivet backend so the signed-in Mac app can publish machine/workspace presence, iOS can get live terminal inbox updates, unread state and push tokens are durable, and zero-config direct attach still works.

**Architecture:** Keep Stack Auth and `cmux.dev` for auth, but move mobile sync out of `manaflow` and into the cmux repo. Add a new cmux backend service that hosts `/api/rivet/*` plus authenticated REST endpoints for machine session minting, heartbeats, daemon tickets, and push registration. Use one Rivet actor per team as the canonical source of truth for machines, workspace summaries, unread state, push-token state, and direct-daemon metadata, persisted in actor-local SQLite through Drizzle schema plus committed generated migrations. Keep GRDB on iOS for cache and offline launch. Keep existing Convex conversation/task features untouched for now, but remove Convex from the terminal/mobile workspace slice.

**Tech Stack:** RivetKit 2.1.6, RivetKit Swift client, Hono, Stack Auth, Next.js auth pages, Drizzle ORM, drizzle-kit, GRDB, SwiftUI, APNS, Tailscale, Cloud Run.

**Testing Strategy:** Backend actor and route behavior must be covered with Vitest in the new backend package. iOS tests stay in `XCTest` with in-memory GRDB and mocked Rivet streams. Mac app unit tests should cover session minting, heartbeat publishing, and direct-daemon metadata publishing without using sleep-based timing. UI automation stays in GitHub Actions for macOS sign-in flow and iOS terminal-home flow. The dogfood gate is not complete until the tagged Mac build, tagged iOS build, and a real signed-in machine have been exercised together.

**Scope Guard:** This plan migrates only the workspace, machine, read/unread, daemon-ticket, and push-notification path. `ConversationsViewModel` may still use Convex for ACP conversations after this plan. A full Convex retirement plan is separate work.

---

## Chunk 1: Freeze The Rivet Cutover Contract

### File Structure

**cmux repo:** `/Users/lawrence/fun/cmuxterm-hq/worktrees/feat-cmuxterm-optional-sign-in`

- Create: `backend/package.json`
- Create: `backend/tsconfig.json`
- Create: `backend/vitest.config.ts`
- Create: `backend/Dockerfile`
- Create: `backend/src/server.ts`
- Create: `backend/src/app.ts`
- Create: `backend/src/env.ts`
- Create: `backend/src/auth/stack.ts`
- Create: `backend/src/rivet/registry.ts`
- Create: `backend/src/rivet/actors/teamInbox/index.ts`
- Create: `backend/src/rivet/actors/teamInbox/schema.ts`
- Create: `backend/src/rivet/actors/teamInbox/drizzle.config.ts`
- Create: `backend/src/rivet/actors/teamInbox/drizzle/migrations.js`
- Create: `backend/src/rivet/actors/teamInbox/drizzle/meta/_journal.json`
- Create: `backend/src/rivet/actors/teamInbox.types.ts`
- Create: `backend/src/routes/health.ts`
- Create: `backend/src/routes/mobile-machine-session.ts`
- Create: `backend/src/routes/mobile-heartbeat.ts`
- Create: `backend/src/routes/mobile-push.ts`
- Create: `backend/src/routes/daemon-ticket.ts`
- Test: `backend/src/rivet/actors/teamInbox.test.ts`
- Test: `backend/src/routes/mobile-heartbeat.test.ts`
- Test: `backend/src/routes/mobile-machine-session.test.ts`
- Test: `backend/src/routes/mobile-push.test.ts`
- Test: `backend/src/routes/daemon-ticket.test.ts`
- Modify: `web/README.md`
- Modify: `docs/superpowers/plans/2026-03-17-cmuxterm-optional-sign-in.md`

**mac app files:**

- Modify: `Sources/Auth/AuthEnvironment.swift`
- Modify: `Sources/MobilePresence/MachineSessionClient.swift`
- Modify: `Sources/MobilePresence/MobileHeartbeatPublisher.swift`
- Modify: `Sources/MobilePresence/MobilePresenceCoordinator.swift`
- Test: `cmuxTests/MachineSessionClientTests.swift`
- Test: `cmuxTests/MobileHeartbeatPublisherTests.swift`

**iOS repo:** `/Users/lawrence/fun/cmuxterm-hq/worktrees/task-move-ios-app-into-cmux-repo`

- Modify: `ios/project.yml`
- Modify: `ios/Sources/Config/Environment.swift`
- Create: `ios/Sources/Rivet/RivetMobileInboxClient.swift`
- Create: `ios/Sources/Rivet/RivetMobileModels.swift`
- Modify: `ios/Sources/Inbox/UnifiedInboxSyncService.swift`
- Modify: `ios/Sources/Inbox/UnifiedInboxItem.swift`
- Modify: `ios/Sources/ViewModels/ConversationsViewModel.swift`
- Modify: `ios/Sources/Terminal/TerminalSidebarStore.swift`
- Modify: `ios/Sources/Terminal/TerminalWorkspaceIdentityService.swift`
- Modify: `ios/Sources/Terminal/TerminalWorkspaceMetadataService.swift`
- Modify: `ios/Sources/Notifications/NotificationManager.swift`
- Test: `ios/cmuxTests/UnifiedInboxSyncServiceTests.swift`
- Test: `ios/cmuxTests/TerminalSidebarStoreTests.swift`
- Test: `ios/cmuxTests/NotificationManagerTests.swift`

### Task 1: Write The Failing Contract Tests

**Files:**
- Create: `backend/src/rivet/actors/teamInbox.test.ts`
- Create: `backend/src/routes/mobile-heartbeat.test.ts`
- Create: `backend/src/routes/daemon-ticket.test.ts`
- Modify: `ios/cmuxTests/UnifiedInboxSyncServiceTests.swift`
- Modify: `cmuxTests/MachineSessionClientTests.swift`

- [ ] **Step 1: Add a failing actor storage test**

Write a test that expects the team actor to persist machines, workspaces, per-user read state, push tokens, and direct-daemon metadata:

```ts
it("stores heartbeat rows and computes unread from latestEventSeq", async () => {
  const actor = await createTestTeamInboxActor(["team", "team_123"]);
  await actor.action("ingestHeartbeat", {
    userId: "user_1",
    machineId: "machine_1",
    displayName: "Mac Mini",
    status: "online",
    tailscaleHostname: "macmini.tailnet.ts.net",
    tailscaleIPs: ["100.64.0.10"],
    directConnect: {
      directHost: "100.64.0.10",
      directPort: 45123,
      directTlsPins: ["pin_a"],
      ticketSecret: "secret_a",
    },
    workspaces: [
      {
        workspaceId: "ws_1",
        title: "cmux",
        preview: "running tests",
        phase: "attached",
        tmuxSessionName: "cmux-1",
        lastActivityAt: 10,
        latestEventSeq: 4,
        lastEventAt: 10,
      },
    ],
  });

  const snapshot = await actor.action("snapshotForUser", "user_1");
  expect(snapshot.items[0]?.unreadCount).toBe(4);
  expect(snapshot.items[0]?.directConnect?.directPort).toBe(45123);
});
```

- [ ] **Step 2: Add a failing iOS sync test**

Write a test that expects `UnifiedInboxSyncService` to merge a live Rivet workspace snapshot with existing conversation rows:

```swift
func testRivetWorkspaceSnapshotMergesIntoInbox() async throws {
    let service = UnifiedInboxSyncService(
        inboxCacheRepository: try makeRepository(),
        publisherFactory: { _ in
            Just([
                RivetMobileWorkspaceRow(
                    workspaceId: "ws_1",
                    machineId: "machine_1",
                    machineDisplayName: "Mac Mini",
                    title: "cmux",
                    preview: "running tests",
                    tmuxSessionName: "cmux-1",
                    lastActivityAt: 1_000,
                    latestEventSeq: 3,
                    lastReadEventSeq: 1,
                    tailscaleHostname: "macmini.tailnet.ts.net",
                    tailscaleIPs: ["100.64.0.10"]
                )
            ])
            .eraseToAnyPublisher()
        }
    )

    service.connect(teamID: "team_123")
    let rows = try await service.workspaceItemsPublisher.firstValue()
    XCTAssertEqual(rows.first?.workspaceID, "ws_1")
    XCTAssertEqual(rows.first?.unreadCount, 2)
}
```

- [ ] **Step 3: Add a failing mac heartbeat client test**

Write a test that expects the Mac app to post to the cmux backend, not the old `manaflow` Convex bridge:

```swift
func testPublishHeartbeatUsesCmuxApiBaseURL() async throws {
    let session = URLSessionMock()
    let client = MachineSessionClient(session: session, authManager: .mockAuthenticated)
    try await client.publishHeartbeat(
        sessionToken: "session",
        payload: .fixture()
    )
    XCTAssertEqual(session.lastRequest?.url?.path, "/api/mobile/heartbeat")
}
```

- [ ] **Step 4: Run the focused tests**

Run:

```bash
cd /Users/lawrence/fun/cmuxterm-hq/worktrees/feat-cmuxterm-optional-sign-in/backend && bunx vitest run src/rivet/actors/teamInbox.test.ts src/routes/mobile-heartbeat.test.ts src/routes/daemon-ticket.test.ts
cd /Users/lawrence/fun/cmuxterm-hq/worktrees/feat-cmuxterm-optional-sign-in && xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux-unit -destination 'platform=macOS' -derivedDataPath /tmp/cmux-rivet-contract -only-testing:cmuxTests/MachineSessionClientTests test
cd /Users/lawrence/fun/cmuxterm-hq/worktrees/task-move-ios-app-into-cmux-repo/ios && xcodebuild test -project cmux.xcodeproj -scheme cmux -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:cmuxTests/UnifiedInboxSyncServiceTests
```

Expected: FAIL because the backend package and Rivet models do not exist yet.

- [ ] **Step 5: Commit**

```bash
cd /Users/lawrence/fun/cmuxterm-hq/worktrees/feat-cmuxterm-optional-sign-in
git add backend cmuxTests/MachineSessionClientTests.swift
git commit -m "test: lock rivet mobile workspace contract"
```

### Task 2: Scaffold The New cmux Backend Package

**Files:**
- Create: `backend/package.json`
- Create: `backend/tsconfig.json`
- Create: `backend/vitest.config.ts`
- Create: `backend/Dockerfile`
- Create: `backend/src/server.ts`
- Create: `backend/src/app.ts`
- Create: `backend/src/env.ts`

- [ ] **Step 1: Create the backend package skeleton**

Use Bun + TypeScript with these dependencies:

```json
{
  "dependencies": {
    "@hono/node-server": "^1.14.0",
    "@stackframe/stack": "^2.9.0",
    "drizzle-orm": "^0.44.2",
    "hono": "^4.7.0",
    "rivetkit": "2.1.6",
    "zod": "^3.25.0"
  },
  "devDependencies": {
    "@types/node": "^24.0.0",
    "drizzle-kit": "^0.31.2",
    "typescript": "^5.8.0",
    "vitest": "^3.1.0"
  }
}
```

Add the script:

```json
"db:generate": "find src/rivet/actors -name drizzle.config.ts -exec drizzle-kit generate --config {} \\;"
```

- [ ] **Step 2: Add env parsing**

`backend/src/env.ts` must require:

```ts
STACK_SECRET_SERVER_KEY
NEXT_PUBLIC_STACK_PROJECT_ID
NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY
RIVET_ENDPOINT
RIVET_PUBLIC_ENDPOINT
APNS_TEAM_ID
APNS_KEY_ID
APNS_PRIVATE_KEY_BASE64
```

Optional local-dev vars:

```ts
PORT
CMUX_API_PORT
CMUX_AUTH_WWW_ORIGIN
CMUX_API_BASE_URL
```

- [ ] **Step 3: Add a tiny health route and server bootstrap**

Mount:

- `GET /api/health`
- `ALL /api/rivet/*`
- `POST /api/mobile/machine-session`
- `POST /api/mobile/heartbeat`
- `POST /api/mobile/push/register`
- `POST /api/mobile/push/remove`
- `POST /api/mobile/push/test`
- `POST /api/daemon-ticket`

- [ ] **Step 4: Re-run the backend tests**

Run:

```bash
cd /Users/lawrence/fun/cmuxterm-hq/worktrees/feat-cmuxterm-optional-sign-in/backend && bunx vitest run src/routes/mobile-heartbeat.test.ts
```

Expected: still FAIL inside unimplemented route/actor behavior, but the package should now boot and typecheck.

- [ ] **Step 5: Commit**

```bash
cd /Users/lawrence/fun/cmuxterm-hq/worktrees/feat-cmuxterm-optional-sign-in
git add backend
git commit -m "feat: scaffold cmux rivet backend"
```

## Chunk 2: Build The Team Inbox Actor And HTTP Surface

### Task 3: Implement The Canonical Team Actor

**Files:**
- Create: `backend/src/rivet/actors/teamInbox.types.ts`
- Create: `backend/src/rivet/actors/teamInbox/index.ts`
- Create: `backend/src/rivet/actors/teamInbox/schema.ts`
- Create: `backend/src/rivet/actors/teamInbox/drizzle.config.ts`
- Create: `backend/src/rivet/actors/teamInbox/drizzle/migrations.js`
- Create: `backend/src/rivet/registry.ts`
- Test: `backend/src/rivet/actors/teamInbox.test.ts`

- [ ] **Step 1: Define the actor schema**

Use actor key `["team", teamId]`.

Define the schema in Drizzle under `src/rivet/actors/teamInbox/schema.ts`, generate the initial migration with `bun run db:generate`, and commit the generated SQL plus journal files. Persist durable rows in actor SQLite:

```sql
machines(
  machine_id TEXT PRIMARY KEY,
  display_name TEXT NOT NULL,
  status TEXT NOT NULL,
  tailscale_hostname TEXT,
  tailscale_ips_json TEXT NOT NULL,
  last_seen_at INTEGER NOT NULL,
  last_workspace_sync_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
)

machine_direct_connect(
  machine_id TEXT PRIMARY KEY,
  direct_host TEXT NOT NULL,
  direct_port INTEGER NOT NULL,
  direct_tls_pins_json TEXT NOT NULL,
  ticket_secret TEXT NOT NULL,
  updated_at INTEGER NOT NULL
)

workspaces(
  workspace_id TEXT PRIMARY KEY,
  machine_id TEXT NOT NULL,
  title TEXT NOT NULL,
  preview TEXT NOT NULL,
  phase TEXT NOT NULL,
  tmux_session_name TEXT NOT NULL,
  last_activity_at INTEGER NOT NULL,
  latest_event_seq INTEGER NOT NULL,
  last_event_at INTEGER,
  deleted_at INTEGER
)

user_workspace_state(
  user_id TEXT NOT NULL,
  workspace_id TEXT NOT NULL,
  last_read_event_seq INTEGER NOT NULL DEFAULT 0,
  archived INTEGER NOT NULL DEFAULT 0,
  pinned INTEGER NOT NULL DEFAULT 0,
  updated_at INTEGER NOT NULL,
  PRIMARY KEY (user_id, workspace_id)
)

push_tokens(
  user_id TEXT NOT NULL,
  token TEXT NOT NULL,
  device_id TEXT,
  bundle_id TEXT NOT NULL,
  environment TEXT NOT NULL,
  platform TEXT NOT NULL,
  updated_at INTEGER NOT NULL,
  PRIMARY KEY (user_id, token)
)

notification_state(
  user_id TEXT NOT NULL,
  workspace_id TEXT NOT NULL,
  last_notified_event_seq INTEGER NOT NULL DEFAULT 0,
  updated_at INTEGER NOT NULL,
  PRIMARY KEY (user_id, workspace_id)
)
```

Use Drizzle query APIs for normal reads and writes. Keep raw `c.db.execute(...)` available only for SQLite-specific features like manual indexes or rare one-off queries.

- [ ] **Step 2: Wire Drizzle migrations into the actor**

Structure the actor folder like this:

```txt
src/rivet/actors/teamInbox/
  index.ts
  schema.ts
  drizzle.config.ts
  drizzle/
    0000_*.sql
    migrations.js
    meta/
      _journal.json
```

Initialize the actor with:

```ts
import { db } from "rivetkit/db/drizzle";
import migrations from "./drizzle/migrations.js";
import { schema } from "./schema";

db: db({ schema, migrations })
```

- [ ] **Step 3: Implement actor actions and events**

Required actions:

- `ingestHeartbeat(args)`
- `snapshotForUser(userId)`
- `markRead(userId, workspaceId, latestEventSeq)`
- `upsertPushToken(userId, token, deviceId, bundleId, environment, platform)`
- `removePushToken(userId, token)`
- `resolveDirectConnection(serverId)`
- `sendTestPush(userId, title, body)`

Required event:

- `inboxSnapshot`, payload `{ items: TeamInboxWorkspaceRow[] }`

Use `c.vars` only for live connection tracking and push debouncing:

```ts
vars: {
  connectedUsers: new Map<string, number>()
}
```

Do not store canonical unread or machine state in `c.vars`.

- [ ] **Step 4: Broadcast deterministic snapshots**

When `ingestHeartbeat` or `markRead` changes visible state:

1. recompute the affected users' inbox rows from SQLite,
2. emit `inboxSnapshot`,
3. only enqueue push for users whose `latest_event_seq > last_read_event_seq`,
4. skip push if that user currently has an open connection in `connectedUsers`.

- [ ] **Step 5: Re-run the actor test suite**

Run:

```bash
cd /Users/lawrence/fun/cmuxterm-hq/worktrees/feat-cmuxterm-optional-sign-in/backend && bunx vitest run src/rivet/actors/teamInbox.test.ts
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
cd /Users/lawrence/fun/cmuxterm-hq/worktrees/feat-cmuxterm-optional-sign-in
git add backend/src/rivet
git commit -m "feat: add rivet team inbox actor"
```

### Task 4: Add Authenticated HTTP Routes Around The Actor

**Files:**
- Create: `backend/src/auth/stack.ts`
- Create: `backend/src/routes/mobile-machine-session.ts`
- Create: `backend/src/routes/mobile-heartbeat.ts`
- Create: `backend/src/routes/mobile-push.ts`
- Create: `backend/src/routes/daemon-ticket.ts`
- Modify: `backend/src/app.ts`
- Test: `backend/src/routes/mobile-machine-session.test.ts`
- Test: `backend/src/routes/mobile-heartbeat.test.ts`
- Test: `backend/src/routes/mobile-push.test.ts`
- Test: `backend/src/routes/daemon-ticket.test.ts`

- [ ] **Step 1: Add Stack-backed auth helpers**

Implement helpers to:

- verify incoming Stack access tokens from iOS and macOS,
- resolve the current user,
- verify the selected team membership,
- derive the first-team fallback server-side when the client does not send one.

- [ ] **Step 2: Implement `POST /api/mobile/machine-session`**

Contract:

```json
{
  "teamSlugOrId": "team_123",
  "machineId": "machine_123",
  "displayName": "Mac Mini"
}
```

Response:

```json
{
  "token": "<short-lived machine session token>",
  "teamId": "team_123",
  "userId": "user_123",
  "machineId": "machine_123",
  "expiresAt": 1710000000000
}
```

The token should be a backend-signed JWT or HMAC payload scoped to:

- team id
- user id
- machine id
- expiry

Do not expose a deploy key or Rivet secret to the app.

- [ ] **Step 3: Implement `POST /api/mobile/heartbeat`**

Behavior:

- verify the machine-session token,
- reject mismatched machine ids,
- normalize timestamps,
- call `teamInbox.ingestHeartbeat(...)`,
- return `202`.

Do not proxy to Convex.

- [ ] **Step 4: Implement `POST /api/mobile/push/*`**

Routes:

- `/api/mobile/push/register`
- `/api/mobile/push/remove`
- `/api/mobile/push/test`

These routes verify the Stack user, then call actor actions:

- `upsertPushToken`
- `removePushToken`
- `sendTestPush`

- [ ] **Step 5: Implement `POST /api/daemon-ticket`**

Keep the current external contract so iOS does not need a protocol redesign:

```json
{
  "server_id": "machine_123",
  "team_id": "team_123",
  "session_id": "cmux-1",
  "attachment_id": "",
  "capabilities": ["session.attach"]
}
```

Route flow:

1. verify Stack user,
2. verify team membership,
3. ask `teamInbox.resolveDirectConnection(serverId)`,
4. sign a short-lived daemon ticket with that machine's `ticket_secret`,
5. return `direct_url`, `direct_tls_pins`, `ticket`, `expires_at`.

- [ ] **Step 6: Re-run route tests**

Run:

```bash
cd /Users/lawrence/fun/cmuxterm-hq/worktrees/feat-cmuxterm-optional-sign-in/backend && bunx vitest run src/routes/mobile-machine-session.test.ts src/routes/mobile-heartbeat.test.ts src/routes/mobile-push.test.ts src/routes/daemon-ticket.test.ts
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
cd /Users/lawrence/fun/cmuxterm-hq/worktrees/feat-cmuxterm-optional-sign-in
git add backend/src/auth backend/src/routes backend/src/app.ts
git commit -m "feat: add rivet mobile sync routes"
```

## Chunk 3: Point The Mac App At The New cmux Backend

### Task 5: Keep Signed-In Publishing And Direct Attach Working

**Files:**
- Modify: `Sources/Auth/AuthEnvironment.swift`
- Modify: `Sources/MobilePresence/MachineSessionClient.swift`
- Modify: `Sources/MobilePresence/MobileHeartbeatPublisher.swift`
- Modify: `Sources/MobilePresence/MobilePresenceCoordinator.swift`
- Modify: `scripts/reload.sh`
- Test: `cmuxTests/MachineSessionClientTests.swift`
- Test: `cmuxTests/MobileHeartbeatPublisherTests.swift`

- [ ] **Step 1: Add failing Mac unit coverage for the new API contract**

Extend tests to cover:

- `machine-session` token refresh without Convex-specific env,
- heartbeat payload with `directConnect`,
- no publish attempt while signed out,
- no publish attempt when Tailscale status is unavailable.

- [ ] **Step 2: Run the focused mac tests**

Run:

```bash
cd /Users/lawrence/fun/cmuxterm-hq/worktrees/feat-cmuxterm-optional-sign-in && xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux-unit -destination 'platform=macOS' -derivedDataPath /tmp/cmux-rivet-mac -only-testing:cmuxTests/MachineSessionClientTests -only-testing:cmuxTests/MobileHeartbeatPublisherTests test
```

Expected: FAIL until the new backend contract is wired up.

- [ ] **Step 3: Update runtime config**

Use:

- `CMUX_API_BASE_URL` for the cmux backend service
- `CMUX_AUTH_WWW_ORIGIN` for browser sign-in

Do not keep any mobile-runtime dependency on:

- `NEXT_PUBLIC_CONVEX_URL`
- `CONVEX_DEPLOY_KEY`
- `MOBILE_MACHINE_JWT_SECRET`

inside the Mac app.

- [ ] **Step 4: Keep heartbeat payload shape stable**

`MobileHeartbeatPublisher` should continue to publish:

- machine id
- display name
- tailscale hostname and IPs
- workspace rows
- `directConnect` with host/port pins and `ticketSecret`

This preserves zero-config attach while only changing the storage backend.

- [ ] **Step 5: Re-run the focused mac tests**

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
cd /Users/lawrence/fun/cmuxterm-hq/worktrees/feat-cmuxterm-optional-sign-in
git add Sources/Auth/AuthEnvironment.swift Sources/MobilePresence scripts/reload.sh cmuxTests
git commit -m "feat: publish mobile presence to cmux rivet backend"
```

### Task 6: Add The Backend Dev And Deployment Path

**Files:**
- Create: `backend/README.md`
- Modify: `web/README.md`
- Modify: `docs/superpowers/plans/2026-03-17-cmuxterm-optional-sign-in.md`

- [ ] **Step 1: Document local dev topology**

Document:

- `web/` runs auth pages on `CMUX_PORT`
- `backend/` runs API + Rivet locally on `CMUX_API_PORT`
- Mac app uses `CMUX_AUTH_WWW_ORIGIN` for sign-in and `CMUX_API_BASE_URL` for presence sync
- iOS uses `API_BASE_URL_*` and `RIVET_PUBLIC_ENDPOINT_*`

- [ ] **Step 2: Document Cloud Run deployment**

Use:

- `RIVET_ENDPOINT`
- `RIVET_PUBLIC_ENDPOINT`
- `APNS_*`
- `STACK_*`

Keep the backend separate from the marketing/docs Next app. `cmux.dev` stays the web/auth origin, `api.cmux.sh` stays the backend origin.

- [ ] **Step 3: Commit**

```bash
cd /Users/lawrence/fun/cmuxterm-hq/worktrees/feat-cmuxterm-optional-sign-in
git add backend/README.md web/README.md docs/superpowers/plans/2026-03-17-cmuxterm-optional-sign-in.md
git commit -m "docs: add rivet mobile backend topology"
```

## Chunk 4: Replace The iOS Workspace Slice With Rivet

### Task 7: Add Rivet Swift Client And Live Inbox Sync

**Files:**
- Modify: `ios/project.yml`
- Modify: `ios/Sources/Config/Environment.swift`
- Create: `ios/Sources/Rivet/RivetMobileInboxClient.swift`
- Create: `ios/Sources/Rivet/RivetMobileModels.swift`
- Modify: `ios/Sources/Inbox/UnifiedInboxSyncService.swift`
- Modify: `ios/Sources/Inbox/UnifiedInboxItem.swift`
- Modify: `ios/Sources/ViewModels/ConversationsViewModel.swift`
- Test: `ios/cmuxTests/UnifiedInboxSyncServiceTests.swift`

- [ ] **Step 1: Add a failing iOS Rivet connection test**

Write a test that expects the inbox sync service to consume a Rivet snapshot stream and persist it to GRDB:

```swift
func testPersistsLatestRivetWorkspaceSnapshot() async throws {
    let repository = try makeRepository()
    let client = RivetMobileInboxClientMock(
        snapshots: [[
            RivetMobileWorkspaceRow.fixture(
                workspaceId: "ws_1",
                latestEventSeq: 5,
                lastReadEventSeq: 2
            )
        ]]
    )
    let service = UnifiedInboxSyncService(
        inboxCacheRepository: repository,
        rivetClientFactory: { _ in client }
    )

    service.connect(teamID: "team_123")
    try await client.awaitFirstSubscription()

    let cached = try repository.load()
    XCTAssertEqual(cached.first?.workspaceID, "ws_1")
    XCTAssertEqual(cached.first?.unreadCount, 3)
}
```

- [ ] **Step 2: Add RivetKit Swift to the iOS project**

In `ios/project.yml` add:

```yaml
  RivetKitSwift:
    url: https://github.com/rivet-dev/rivetkit-swift
    from: "2.1.6"
```

and add the `RivetKitClient` product to the `cmux` target.

- [ ] **Step 3: Add environment keys**

`Environment.swift` should read:

- `RIVET_PUBLIC_ENDPOINT_DEV`
- `RIVET_PUBLIC_ENDPOINT_PROD`

Do not remove `CONVEX_URL_*` yet because conversation/task screens still need them.

- [ ] **Step 4: Implement the Rivet inbox client**

`RivetMobileInboxClient` should:

1. build `ClientConfig(endpoint: Environment.current.rivetPublicEndpoint)`,
2. connect to actor `teamInbox` with key `["team", teamID]`,
3. pass connection params containing the current Stack access token,
4. expose an `AnyPublisher<[RivetMobileWorkspaceRow], Never>` backed by `inboxSnapshot`,
5. reconnect cleanly on auth refresh.

- [ ] **Step 5: Replace the default publisher in `UnifiedInboxSyncService`**

Stop subscribing to:

```swift
"mobileInbox:listForUser"
```

and replace it with `RivetMobileInboxClient.workspaceRowsPublisher(teamID:)`.

`ConversationsViewModel` should continue to merge:

- Convex conversation rows
- Rivet workspace rows

without changing the visible sort order logic.

- [ ] **Step 6: Re-run the focused iOS tests**

Run:

```bash
cd /Users/lawrence/fun/cmuxterm-hq/worktrees/task-move-ios-app-into-cmux-repo/ios && xcodebuild test -project cmux.xcodeproj -scheme cmux -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:cmuxTests/UnifiedInboxSyncServiceTests -only-testing:cmuxTests/ConversationsViewModelTests
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
cd /Users/lawrence/fun/cmuxterm-hq/worktrees/task-move-ios-app-into-cmux-repo
git add ios/project.yml ios/Sources/Config/Environment.swift ios/Sources/Rivet ios/Sources/Inbox ios/Sources/ViewModels/ConversationsViewModel.swift ios/cmuxTests
git commit -m "ios: stream workspace inbox from rivet"
```

### Task 8: Remove Terminal-Only Convex Dependence

**Files:**
- Modify: `ios/Sources/Terminal/TerminalSidebarStore.swift`
- Modify: `ios/Sources/Terminal/TerminalWorkspaceIdentityService.swift`
- Modify: `ios/Sources/Terminal/TerminalWorkspaceMetadataService.swift`
- Test: `ios/cmuxTests/TerminalSidebarStoreTests.swift`

- [ ] **Step 1: Add failing terminal slice tests**

Add tests for:

- remote workspace open marks read through the new backend path,
- discovered machines do not require Convex reservation,
- starting a local workspace does not fail when the Convex identity service is absent.

- [ ] **Step 2: Replace the remote read marker**

Stop calling:

```swift
"mobileWorkspaces:markRead"
```

Replace it with a lightweight API client or Rivet action:

```swift
POST /api/mobile/workspaces/mark-read
```

or actor action `markRead`, whichever keeps the terminal slice simpler. Pick one and use it consistently across iOS and backend tests.

- [ ] **Step 3: Make workspace identity enrichment optional**

`TerminalWorkspaceIdentityService` and `TerminalWorkspaceMetadataService` should default to no-op implementations for terminal dogfood. Local and discovered workspaces already have:

- `tmuxSessionName`
- `remoteWorkspaceID`
- direct attach metadata

That is enough for terminal open/attach. Convex-linked task metadata is optional enrichment and must not block terminal creation.

- [ ] **Step 4: Re-run the focused terminal tests**

Run:

```bash
cd /Users/lawrence/fun/cmuxterm-hq/worktrees/task-move-ios-app-into-cmux-repo/ios && xcodebuild test -project cmux.xcodeproj -scheme cmux -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:cmuxTests/TerminalSidebarStoreTests
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd /Users/lawrence/fun/cmuxterm-hq/worktrees/task-move-ios-app-into-cmux-repo
git add ios/Sources/Terminal ios/cmuxTests/TerminalSidebarStoreTests.swift
git commit -m "ios: remove convex dependency from terminal workspace flow"
```

### Task 9: Move Push Token Sync Off Convex

**Files:**
- Modify: `ios/Sources/Notifications/NotificationManager.swift`
- Modify: `ios/Sources/Auth/AuthManager.swift`
- Test: `ios/cmuxTests/NotificationManagerTests.swift`

- [ ] **Step 1: Add failing push sync tests**

Write tests that expect:

- `syncTokenIfPossible()` to hit `/api/mobile/push/register`,
- logout to hit `/api/mobile/push/remove`,
- test-push button to hit `/api/mobile/push/test`.

- [ ] **Step 2: Replace `LiveNotificationPushSyncer`**

Stop using Convex mutations:

- `pushTokens:upsert`
- `pushTokens:remove`
- `pushTokens:sendTest`

Replace them with authenticated REST calls to the cmux backend.

- [ ] **Step 3: Re-run the notification tests**

Run:

```bash
cd /Users/lawrence/fun/cmuxterm-hq/worktrees/task-move-ios-app-into-cmux-repo/ios && xcodebuild test -project cmux.xcodeproj -scheme cmux -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:cmuxTests/NotificationManagerTests
```

Expected: PASS.

- [ ] **Step 4: Commit**

```bash
cd /Users/lawrence/fun/cmuxterm-hq/worktrees/task-move-ios-app-into-cmux-repo
git add ios/Sources/Notifications ios/Sources/Auth/AuthManager.swift ios/cmuxTests/NotificationManagerTests.swift
git commit -m "ios: sync push tokens through cmux backend"
```

## Chunk 5: Dogfood The Full Rivet Path And Retire The Convex Branch Dependency

### Task 10: Run The End-To-End Dogfood Gate

**Files:**
- Modify: `docs/superpowers/plans/2026-03-17-rivet-mobile-workspace-state.md`
- Modify: `ios/README.md`
- Modify: `backend/README.md`

- [ ] **Step 1: Run backend verification**

Run:

```bash
cd /Users/lawrence/fun/cmuxterm-hq/worktrees/feat-cmuxterm-optional-sign-in/backend && bunx vitest run
cd /Users/lawrence/fun/cmuxterm-hq/worktrees/feat-cmuxterm-optional-sign-in/backend && bunx tsc --noEmit
```

Expected: PASS.

- [ ] **Step 2: Run safe local unit gates**

Run:

```bash
cd /Users/lawrence/fun/cmuxterm-hq/worktrees/feat-cmuxterm-optional-sign-in && xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux-unit -destination 'platform=macOS' -derivedDataPath /tmp/cmux-rivet-final build-for-testing
cd /Users/lawrence/fun/cmuxterm-hq/worktrees/task-move-ios-app-into-cmux-repo/ios && xcodebuild test -project cmux.xcodeproj -scheme cmux -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:cmuxTests/UnifiedInboxSyncServiceTests -only-testing:cmuxTests/TerminalSidebarStoreTests -only-testing:cmuxTests/NotificationManagerTests
```

Expected: PASS.

- [ ] **Step 3: Run the macOS UI flow in GitHub Actions**

Trigger:

```bash
gh workflow run test-e2e.yml --repo manaflow-ai/cmux \
  -f ref=feat-cmuxterm-optional-sign-in \
  -f test_filter="SettingsAccountUITests" \
  -f record_video=true
```

Expected: PASS with the browser sign-in button still present and optional.

- [ ] **Step 4: Reload tagged builds**

Run:

```bash
cd /Users/lawrence/fun/cmuxterm-hq/worktrees/feat-cmuxterm-optional-sign-in && CMUX_API_BASE_URL=http://127.0.0.1:4010 ./scripts/reload.sh --tag rivet-mobile
cd /Users/lawrence/fun/cmuxterm-hq/worktrees/task-move-ios-app-into-cmux-repo && ./ios/scripts/reload.sh --tag ios-rivet-mobile
```

Expected:

- tagged Mac app launches with optional sign-in,
- tagged iOS app installs on simulator and best-effort on phone.

- [ ] **Step 5: Manual dogfood checklist**

Verify on real hardware:

1. Signed-out Mac app still works for local-only terminal use.
2. Optional `Sign In in Browser` still round-trips through `cmux.dev`.
3. Signed-in Mac appears at the top of the iOS `Terminals` screen.
4. New and existing workspaces update live without waiting for app relaunch.
5. Opening a workspace marks it read and the unread badge clears on another device.
6. APNS arrives when the iPhone is backgrounded and opens the correct workspace.
7. `daemon-ticket` still opens the workspace directly instead of showing the host editor.

- [ ] **Step 6: Stop depending on the unmerged `manaflow` mobile branch**

After the manual gate passes:

- point iOS dogfood envs to the cmux backend only,
- stop running the old `manaflow` `apps/www` dev server for mobile sync,
- update the iOS README so the terminal/mobile sync path no longer references Convex scripts for workspace sync.

- [ ] **Step 7: Commit**

```bash
cd /Users/lawrence/fun/cmuxterm-hq/worktrees/feat-cmuxterm-optional-sign-in
git add docs/superpowers/plans/2026-03-17-rivet-mobile-workspace-state.md backend/README.md web/README.md
git commit -m "docs: record rivet mobile dogfood gate"
```

## Open Questions Already Resolved By This Plan

- Use Rivet as the canonical source of truth for workspace, machine, read/unread, push-token, and direct-daemon metadata. Do not add Postgres for this first cut.
- Use actor-per-team, keyed as `["team", teamId]`.
- Use Drizzle on top of actor SQLite, with generated migrations committed to source control per actor folder.
- Do not store canonical business state in `c.vars`.
- Do not migrate ACP conversations off Convex in this plan.
- Do not keep the terminal/mobile sync path in `manaflow`.

## Secrets And Config To Carry Forward

**cmux backend only:**

- `STACK_SECRET_SERVER_KEY`
- `NEXT_PUBLIC_STACK_PROJECT_ID`
- `NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY`
- `RIVET_ENDPOINT`
- `RIVET_PUBLIC_ENDPOINT`
- `APNS_TEAM_ID`
- `APNS_KEY_ID`
- `APNS_PRIVATE_KEY_BASE64`

**mac app public/runtime config:**

- `CMUX_AUTH_WWW_ORIGIN`
- `CMUX_API_BASE_URL`

**iOS public/runtime config:**

- `API_BASE_URL_DEV`
- `API_BASE_URL_PROD`
- `RIVET_PUBLIC_ENDPOINT_DEV`
- `RIVET_PUBLIC_ENDPOINT_PROD`
- existing Stack public keys

Plan complete and saved to `docs/superpowers/plans/2026-03-17-rivet-mobile-workspace-state.md`. Ready to execute?
