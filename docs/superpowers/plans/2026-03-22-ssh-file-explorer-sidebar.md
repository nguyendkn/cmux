# SSH-Aware File Explorer Sidebar Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a toggleable right-side file explorer that shows the current workspace's terminal directories, works for local and SSH workspaces, and merges nested roots without duplicating whole subtrees.

**Architecture:** Do not try to embed Finder itself. macOS does not expose Finder's full browser UI as a reusable view, so the explorer should be a native cmux sidebar built from an AppKit `NSOutlineView` wrapped in SwiftUI, with Finder-like affordances such as file icons, disclosure triangles, drag targets, and Finder reveal/open actions for local paths. The data model is workspace-scoped, groups roots by host scope (`local` vs a specific SSH target), and uses lazy loading so local directories come from `FileManager` while remote directories come from a new `fs.list` RPC on `cmuxd-remote`.

**Tech Stack:** SwiftUI, AppKit `NSOutlineView`, AppStorage, existing `Workspace` and `AppDelegate` window state, Go remote daemon (`cmuxd-remote`), XCTest, XCUITest, localized strings in `Resources/Localizable.xcstrings`.

---

## Chunk 1: Product Decisions And File Map

### Resolved Product Decisions

- Scope the explorer to the selected workspace, not the whole app. The right sidebar should show roots for the currently selected workspace's terminal surfaces because that matches the existing left-sidebar-per-window model and keeps the UI legible.
- Only terminal surfaces contribute roots. Browser and markdown panels can still live in the workspace, but they should not create file explorer roots.
- Merge roots by host scope first, then by canonical path. `/Users/lawrence/fun` on the local machine and `~/fun` on `dev@host` must never merge.
- Handle nested paths by building a forest, not a flat list. If surface A is `~/fun` and surface B is `~/fun/a`, show one root for `~/fun`, auto-materialize the `a` branch, and mark that branch as referenced by surface B.
- Keep v1 read-only for filesystem mutation. Browsing, expansion, selection, copy path, reveal in Finder for local paths, and maybe double-click open for local files are enough. No rename, move, delete, create file, or remote write paths in the first pass.
- Do not add filesystem watchers in v1. Refresh on expand, workspace change, root change, explicit refresh, and sidebar re-open is sufficient.
- Remote browsing should fail soft. If SSH is connected but the daemon is not ready or `fs.list` fails, show an inline error row with a retry button instead of breaking the whole workspace.
- Add a dedicated shortcut instead of overloading the existing left-sidebar toggle. Per repo policy, every new shortcut must go through `KeyboardShortcutSettings`.

### File Structure

- Create: `Sources/FileExplorer/FileExplorerSidebarState.swift`
  Purpose: Window-scoped right-sidebar visibility and width state.
- Create: `Sources/FileExplorer/FileExplorerModels.swift`
  Purpose: Node IDs, host-scope identity, root markers, entry payloads, and lightweight view models.
- Create: `Sources/FileExplorer/FileExplorerRootResolver.swift`
  Purpose: Turn workspace terminal directories into merged root groups, including nested-path collapse and remote/home canonicalization.
- Create: `Sources/FileExplorer/FileExplorerProvider.swift`
  Purpose: Shared provider protocol and common result types.
- Create: `Sources/FileExplorer/LocalFileExplorerProvider.swift`
  Purpose: Local directory listing backed by `FileManager`, off the main actor.
- Create: `Sources/FileExplorer/RemoteFileExplorerProvider.swift`
  Purpose: Remote directory listing backed by `cmuxd-remote fs.list`.
- Create: `Sources/FileExplorer/FileExplorerStore.swift`
  Purpose: Async tree state, lazy child loading, cache invalidation, selection, and error handling.
- Create: `Sources/FileExplorer/FileExplorerSidebarView.swift`
  Purpose: Right-sidebar shell, header, empty state, loading state, and tree host.
- Create: `Sources/FileExplorer/FileExplorerOutlineView.swift`
  Purpose: `NSOutlineView` bridge for Finder-like tree behavior on macOS.
- Modify: `Sources/ContentView.swift`
  Purpose: Add the trailing sidebar layout, a second resize handle, and workspace/store wiring.
- Modify: `Sources/AppDelegate.swift`
  Purpose: Create, inject, persist, and toggle the new file explorer state per main window.
- Modify: `Sources/SessionPersistence.swift`
  Purpose: Persist optional file explorer visibility and width without breaking old snapshots.
- Modify: `Sources/Workspace.swift`
  Purpose: Expose ordered terminal-root inputs and remote daemon metadata needed by the explorer.
- Modify: `Sources/Update/UpdateTitlebarAccessory.swift`
  Purpose: Add the titlebar button and accessibility identifiers for the new toggle.
- Modify: `Sources/KeyboardShortcutSettings.swift`
  Purpose: Add the new customizable action and defaults metadata.
- Modify: `Sources/cmuxApp.swift`
  Purpose: Add the View-menu command and shortcut settings row.
- Modify: `Resources/Localizable.xcstrings`
  Purpose: Localize all new strings in English and Japanese.
- Modify: `daemon/remote/cmd/cmuxd-remote/main.go`
  Purpose: Add `fs.list` RPC and advertise the new capability.
- Modify: `daemon/remote/cmd/cmuxd-remote/main_test.go`
  Purpose: Cover the new daemon capability and RPC behavior.
- Modify: `daemon/remote/README.md`
  Purpose: Document the new RPC contract.
- Create: `cmuxTests/FileExplorerRootResolverTests.swift`
  Purpose: Root grouping and nested-path behavior.
- Create: `cmuxTests/FileExplorerStoreTests.swift`
  Purpose: Tree loading, cache invalidation, and provider error handling.
- Create: `cmuxTests/RemoteFileExplorerProviderTests.swift`
  Purpose: Swift-side decoding and remote error mapping.
- Modify: `cmuxTests/AppDelegateShortcutRoutingTests.swift`
  Purpose: Verify the new shortcut routes to the active window's file explorer state.
- Modify: `cmuxTests/SessionPersistenceTests.swift`
  Purpose: Verify file explorer snapshot save/load compatibility.
- Modify: `cmuxTests/WorkspaceUnitTests.swift`
  Purpose: Verify new keyboard shortcut labels/defaults if kept in the existing shortcut coverage file.
- Create: `cmuxUITests/FileExplorerSidebarUITests.swift`
  Purpose: Smoke test the titlebar toggle and right-sidebar visibility/resize path.

## Chunk 2: Window State, Persistence, And Root Resolution

### Task 1: Add Window-Scoped File Explorer State

**Files:**
- Create: `Sources/FileExplorer/FileExplorerSidebarState.swift`
- Modify: `Sources/AppDelegate.swift`
- Modify: `Sources/SessionPersistence.swift`
- Test: `cmuxTests/SessionPersistenceTests.swift`
- Test: `cmuxTests/AppDelegateShortcutRoutingTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
func testSessionWindowSnapshotRoundTripsFileExplorerState() throws {
    let snapshot = SessionWindowSnapshot(
        frame: nil,
        display: nil,
        tabManager: makeTabManagerSnapshot(),
        sidebar: SessionSidebarSnapshot(isVisible: true, selection: .tabs, width: 220),
        fileExplorer: SessionFileExplorerSnapshot(isVisible: true, width: 280)
    )
    XCTAssertEqual(snapshot.fileExplorer?.isVisible, true)
    XCTAssertEqual(snapshot.fileExplorer?.width, 280)
}

func testToggleFileExplorerShortcutUsesActiveMainWindowContext() {
    // Mirror the existing toggle-sidebar routing tests, but assert on fileExplorerState.
}
```

- [ ] **Step 2: Run the targeted tests to verify they fail**

Run: `xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux-unit -destination 'platform=macOS' -only-testing:cmuxTests/SessionPersistenceTests -only-testing:cmuxTests/AppDelegateShortcutRoutingTests test`

Expected: FAIL because `SessionWindowSnapshot` and `MainWindowContext` do not yet know about `fileExplorer`, and `AppDelegate` has no file-explorer toggle path.

- [ ] **Step 3: Implement the minimal state and persistence**

```swift
@MainActor
final class FileExplorerSidebarState: ObservableObject {
    @Published var isVisible: Bool
    @Published var persistedWidth: CGFloat

    init(isVisible: Bool = false, persistedWidth: CGFloat = 280) {
        self.isVisible = isVisible
        self.persistedWidth = persistedWidth
    }

    func toggle() {
        isVisible.toggle()
    }
}

struct SessionFileExplorerSnapshot: Codable, Sendable {
    var isVisible: Bool
    var width: Double?
}
```

Implementation notes:
- Keep `SessionWindowSnapshot.fileExplorer` optional so older snapshots still decode with `version == 1`.
- Mirror the existing left-sidebar width sanitization with a dedicated helper for the right sidebar instead of reusing the left-sidebar name everywhere.
- Extend `MainWindowContext` and `registerMainWindow(...)` to carry the new state object.
- Add `toggleFileExplorerInActiveMainWindow()` beside `toggleSidebarInActiveMainWindow()`.

- [ ] **Step 4: Run the targeted tests to verify they pass**

Run: `xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux-unit -destination 'platform=macOS' -only-testing:cmuxTests/SessionPersistenceTests -only-testing:cmuxTests/AppDelegateShortcutRoutingTests test`

Expected: PASS for the new snapshot and routing coverage.

- [ ] **Step 5: Commit**

```bash
git add Sources/FileExplorer/FileExplorerSidebarState.swift Sources/AppDelegate.swift Sources/SessionPersistence.swift cmuxTests/SessionPersistenceTests.swift cmuxTests/AppDelegateShortcutRoutingTests.swift
git commit -m "feat: persist file explorer sidebar state"
```

### Task 2: Resolve Workspace Roots And Nested Paths

**Files:**
- Create: `Sources/FileExplorer/FileExplorerModels.swift`
- Create: `Sources/FileExplorer/FileExplorerRootResolver.swift`
- Modify: `Sources/Workspace.swift`
- Test: `cmuxTests/FileExplorerRootResolverTests.swift`

- [ ] **Step 1: Write the failing root-resolution tests**

```swift
func testNestedLocalRootsCollapseIntoSingleForest() {
    let roots = FileExplorerRootResolver.resolve(
        orderedTerminalRoots: [
            .local(panelID: a, directory: "~/fun"),
            .local(panelID: b, directory: "~/fun/a")
        ],
        workspace: .local(homeDirectory: "/Users/lawrence")
    )

    XCTAssertEqual(roots.count, 1)
    XCTAssertEqual(roots[0].displayPath, "~/fun")
    XCTAssertTrue(roots[0].containsReferencedDescendant("~/fun/a"))
}

func testSamePathStringDoesNotMergeAcrossLocalAndSSHScopes() {
    XCTAssertEqual(roots.count, 2)
}
```

- [ ] **Step 2: Run the new resolver tests to verify they fail**

Run: `xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux-unit -destination 'platform=macOS' -only-testing:cmuxTests/FileExplorerRootResolverTests test`

Expected: FAIL because the resolver and host-scope types do not exist yet.

- [ ] **Step 3: Implement the resolver**

```swift
enum FileExplorerHostScope: Hashable {
    case local
    case ssh(destination: String, port: Int?, identityFingerprint: String?)
}

struct FileExplorerRootInput {
    let panelID: UUID
    let hostScope: FileExplorerHostScope
    let rawDirectory: String
}
```

Resolver rules:
- Read terminal directories in visual order from the selected workspace.
- Reuse `SidebarBranchOrdering.canonicalDirectoryKey(...)` and `SidebarBranchOrdering.inferredRemoteHomeDirectory(...)` so tilde expansion stays consistent with the existing sidebar.
- Partition roots by `FileExplorerHostScope`.
- Sort by canonical path depth inside each host scope.
- If a root is inside an existing root, do not create a duplicate top-level root. Instead, mark the descendant node as an explicit surface root for its panel.
- Preserve original display strings (`~/fun` when possible) instead of always showing absolute paths.

- [ ] **Step 4: Run the resolver tests to verify they pass**

Run: `xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux-unit -destination 'platform=macOS' -only-testing:cmuxTests/FileExplorerRootResolverTests test`

Expected: PASS with coverage for local, SSH, and nested-root behavior.

- [ ] **Step 5: Commit**

```bash
git add Sources/FileExplorer/FileExplorerModels.swift Sources/FileExplorer/FileExplorerRootResolver.swift Sources/Workspace.swift cmuxTests/FileExplorerRootResolverTests.swift
git commit -m "feat: resolve merged file explorer roots"
```

## Chunk 3: Providers, Store, And Remote RPC

### Task 3: Build Local Provider And Tree Store

**Files:**
- Create: `Sources/FileExplorer/FileExplorerProvider.swift`
- Create: `Sources/FileExplorer/LocalFileExplorerProvider.swift`
- Create: `Sources/FileExplorer/FileExplorerStore.swift`
- Test: `cmuxTests/FileExplorerStoreTests.swift`

- [ ] **Step 1: Write failing store/provider tests**

```swift
func testLoadingChildrenSortsDirectoriesBeforeFiles() async throws {
    let store = FileExplorerStore(provider: FakeProvider(...))
    let children = try await store.loadChildren(for: rootID)
    XCTAssertEqual(children.map(\.name), ["Sources", "README.md"])
}

func testProviderErrorsBecomeNodeErrorsWithoutDroppingSiblingState() async throws {
    // Expand one node, fail another, confirm cache survives.
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux-unit -destination 'platform=macOS' -only-testing:cmuxTests/FileExplorerStoreTests test`

Expected: FAIL because the provider protocol and store do not exist yet.

- [ ] **Step 3: Implement the local provider and store**

```swift
protocol FileExplorerProvider: Sendable {
    func listChildren(for request: FileExplorerListRequest) async throws -> [FileExplorerEntry]
}

actor FileExplorerStore {
    func refreshRoots(_ roots: [FileExplorerResolvedRoot]) async
    func toggleExpansion(for nodeID: FileExplorerNodeID) async
    func refreshNode(_ nodeID: FileExplorerNodeID) async
}
```

Implementation notes:
- Do all filesystem I/O off-main.
- Store children by stable node ID so expansion state survives workspace titlebar and sidebar refreshes.
- Sort directories before files, then use localized case-insensitive name sort within each bucket.
- Populate icon lookups in the view layer with `NSWorkspace.shared.icon(forFile:)` for local nodes only. The provider should stay data-only.
- Expose a small `refresh` entry point for the header button and root changes.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux-unit -destination 'platform=macOS' -only-testing:cmuxTests/FileExplorerStoreTests test`

Expected: PASS for store state and local sort/error handling.

- [ ] **Step 5: Commit**

```bash
git add Sources/FileExplorer/FileExplorerProvider.swift Sources/FileExplorer/LocalFileExplorerProvider.swift Sources/FileExplorer/FileExplorerStore.swift cmuxTests/FileExplorerStoreTests.swift
git commit -m "feat: add local file explorer store"
```

### Task 4: Add Remote Directory Listing Through `cmuxd-remote`

**Files:**
- Create: `Sources/FileExplorer/RemoteFileExplorerProvider.swift`
- Modify: `Sources/Workspace.swift`
- Modify: `daemon/remote/cmd/cmuxd-remote/main.go`
- Modify: `daemon/remote/cmd/cmuxd-remote/main_test.go`
- Modify: `daemon/remote/README.md`
- Test: `cmuxTests/RemoteFileExplorerProviderTests.swift`
- Test: `daemon/remote/cmd/cmuxd-remote/main_test.go`

- [ ] **Step 1: Write the failing daemon and Swift-side tests**

```go
func TestHelloAdvertisesFSListCapability(t *testing.T) {}
func TestFSListReturnsDirectoryEntries(t *testing.T) {}
func TestFSListRejectsMissingPath(t *testing.T) {}
```

```swift
func testRemoteProviderMapsFSListResponseIntoExplorerEntries() async throws {}
func testRemoteProviderReturnsInlineErrorWhenDaemonPathIsMissing() async throws {}
```

- [ ] **Step 2: Run the targeted tests to verify they fail**

Run: `go test ./daemon/remote/cmd/cmuxd-remote -run 'TestHelloAdvertisesFSListCapability|TestFSList'`

Run: `xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux-unit -destination 'platform=macOS' -only-testing:cmuxTests/RemoteFileExplorerProviderTests test`

Expected: FAIL because `fs.list` is not implemented or advertised and the Swift provider does not exist.

- [ ] **Step 3: Implement the remote RPC and provider**

```go
case "fs.list":
    return s.handleFSList(req)
```

```go
Result: map[string]any{
    "path": path,
    "entries": []map[string]any{
        {"name": "Sources", "path": "/repo/Sources", "kind": "directory"},
        {"name": "README.md", "path": "/repo/README.md", "kind": "file"},
    },
}
```

```swift
struct RemoteFileExplorerProvider: FileExplorerProvider {
    let configuration: WorkspaceRemoteConfiguration
    let remotePath: String
}
```

Implementation notes:
- Keep the daemon RPC minimal: path in, shallow directory listing out, no recursion.
- Advertise a new capability string such as `fs.list`.
- Return directory, file, and symlink kinds, but keep expansion limited to entries that are known directories in v1.
- In Swift, use `workspace.remoteDaemonStatus.remotePath` plus `workspace.remoteConfiguration` to create the provider.
- It is acceptable for v1 to use a short-lived `WorkspaceRemoteDaemonRPCClient` per load, because the tree store will cache responses and loads are user-driven rather than keystroke-hot.

- [ ] **Step 4: Run the targeted tests to verify they pass**

Run: `go test ./daemon/remote/cmd/cmuxd-remote -run 'TestHelloAdvertisesFSListCapability|TestFSList'`

Run: `xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux-unit -destination 'platform=macOS' -only-testing:cmuxTests/RemoteFileExplorerProviderTests test`

Expected: PASS for the new daemon capability and Swift-side provider behavior.

- [ ] **Step 5: Commit**

```bash
git add Sources/FileExplorer/RemoteFileExplorerProvider.swift Sources/Workspace.swift daemon/remote/cmd/cmuxd-remote/main.go daemon/remote/cmd/cmuxd-remote/main_test.go daemon/remote/README.md cmuxTests/RemoteFileExplorerProviderTests.swift
git commit -m "feat: add remote file explorer listing rpc"
```

## Chunk 4: UI Integration, Verification, And Release Hygiene

### Task 5: Integrate The Right Sidebar UI, Titlebar Toggle, Menu Item, And Shortcut

**Files:**
- Create: `Sources/FileExplorer/FileExplorerSidebarView.swift`
- Create: `Sources/FileExplorer/FileExplorerOutlineView.swift`
- Modify: `Sources/ContentView.swift`
- Modify: `Sources/AppDelegate.swift`
- Modify: `Sources/Update/UpdateTitlebarAccessory.swift`
- Modify: `Sources/KeyboardShortcutSettings.swift`
- Modify: `Sources/cmuxApp.swift`
- Modify: `Resources/Localizable.xcstrings`
- Test: `cmuxTests/AppDelegateShortcutRoutingTests.swift`
- Test: `cmuxTests/WorkspaceUnitTests.swift`
- Test: `cmuxUITests/FileExplorerSidebarUITests.swift`

- [ ] **Step 1: Write the failing UI and shortcut tests**

```swift
func testToggleFileExplorerShortcutMetadata() {
    XCTAssertEqual(KeyboardShortcutSettings.Action.toggleFileExplorer.label, "Toggle File Explorer")
}
```

```swift
func testTitlebarButtonShowsAndHidesRightSidebar() {
    // UI test: click titlebarControl.toggleFileExplorer and assert FileExplorerSidebar exists/disappears.
}
```

- [ ] **Step 2: Run the unit tests to verify they fail**

Run: `xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux-unit -destination 'platform=macOS' -only-testing:cmuxTests/AppDelegateShortcutRoutingTests -only-testing:cmuxTests/WorkspaceUnitTests test`

Expected: FAIL because the new action, menu route, and titlebar button do not exist.

- [ ] **Step 3: Implement the UI wiring**

```swift
enum KeyboardShortcutSettings.Action: String, CaseIterable {
    case toggleFileExplorer
}
```

```swift
TitlebarControlButton(config: config, action: onToggleFileExplorer) {
    iconLabel(systemName: "sidebar.right", config: config)
}
.accessibilityIdentifier("titlebarControl.toggleFileExplorer")
```

```swift
HStack(spacing: 0) {
    leadingSidebarIfVisible
    terminalContent
    trailingFileExplorerIfVisible
}
```

Implementation notes:
- Mirror the existing left-sidebar resize behavior with a trailing resize handle, but do not refactor the entire left-sidebar system into a generic abstraction unless the duplication is obvious and small.
- Keep the right sidebar hidden by default.
- Add a `View > Toggle File Explorer` menu item and wire the keyboard shortcut through `KeyboardShortcutSettings`.
- Add a header in the right sidebar with a localized title, current host label (`Local` or `dev@host:22`), and a refresh button.
- Show local Finder actions only for local nodes. Remote nodes should expose copy-path and refresh, not Finder reveal.
- Every new user-visible label, tooltip, button title, empty state, and error message must go through `String(localized:..., defaultValue: ...)` with English and Japanese translations.

- [ ] **Step 4: Add the UI smoke test**

Create `cmuxUITests/FileExplorerSidebarUITests.swift` with at least:
- titlebar button toggles sidebar visibility
- sidebar can resize from the right edge
- nested-root rendering is covered by unit tests, not UI tests

Reasoning:
- Local UI behavior is deterministic in CI.
- Real SSH end-to-end UI testing is not practical without a stable SSH fixture, so cover remote behavior with daemon and provider unit tests instead of fake source-shape UI tests.

- [ ] **Step 5: Run the targeted checks**

Run: `xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux-unit -destination 'platform=macOS' -only-testing:cmuxTests/AppDelegateShortcutRoutingTests -only-testing:cmuxTests/WorkspaceUnitTests test`

Run: `gh workflow run test-e2e.yml --repo manaflow-ai/cmux -f ref=task-file-explorer-ssh-sidebar -f test_filter="FileExplorerSidebarUITests" -f record_video=true`

Run: `gh run list --repo manaflow-ai/cmux --workflow test-e2e.yml --limit 3`

Run: `gh run watch --repo manaflow-ai/cmux <run-id>`

Expected: unit tests PASS, and the UI workflow finishes green with a recording artifact.

- [ ] **Step 6: Commit**

```bash
git add Sources/FileExplorer/FileExplorerSidebarView.swift Sources/FileExplorer/FileExplorerOutlineView.swift Sources/ContentView.swift Sources/AppDelegate.swift Sources/Update/UpdateTitlebarAccessory.swift Sources/KeyboardShortcutSettings.swift Sources/cmuxApp.swift Resources/Localizable.xcstrings cmuxTests/AppDelegateShortcutRoutingTests.swift cmuxTests/WorkspaceUnitTests.swift cmuxUITests/FileExplorerSidebarUITests.swift
git commit -m "feat: add file explorer sidebar ui"
```

### Task 6: Dogfood The Feature And Close Out The Branch

**Files:**
- Modify: branch tip only, no new source files expected
- Test: existing checks plus manual dogfood

- [ ] **Step 1: Build and reload a tagged app**

Run: `./scripts/reload.sh --tag task-file-explorer-ssh-sidebar`

Expected: tagged `cmux DEV task-file-explorer-ssh-sidebar.app` launches without touching the untagged debug app.

- [ ] **Step 2: Manually verify the local workspace path**

Check:
- open a workspace rooted at a temp directory with a few nested folders and files
- confirm the right sidebar shows the root and lazy-loads children
- confirm clicking the titlebar button, menu item, and shortcut all toggle the same sidebar state
- confirm double-click or context-menu Finder reveal only appears for local paths

- [ ] **Step 3: Manually verify the nested-root path**

Check:
- surface A at `~/fun`
- surface B at `~/fun/a`
- confirm there is one top-level root for `~/fun`
- confirm the `a` node appears inside that tree and carries the secondary-surface marker instead of duplicating the whole root

- [ ] **Step 4: Manually verify the SSH path**

Check:
- launch `cmux ssh <destination>`
- wait for `remote.daemon` to reach ready
- confirm the explorer switches host label to the SSH target
- expand a remote directory and verify entries load
- intentionally break the remote path once and confirm the sidebar shows an inline retryable error instead of crashing

- [ ] **Step 5: Push and prepare the PR**

```bash
git push -u origin task-file-explorer-ssh-sidebar
gh pr create --repo manaflow-ai/cmux --base main --head task-file-explorer-ssh-sidebar --title "feat: add ssh-aware file explorer sidebar" --body-file /tmp/task-file-explorer-ssh-sidebar-pr.md
```

Suggested PR body:

```md
## Summary
- add a right-side file explorer for the selected workspace
- merge nested terminal roots and keep local and SSH trees separate
- add remote daemon filesystem listing support for SSH workspaces

## Testing
- xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux-unit -destination 'platform=macOS' -only-testing:cmuxTests/FileExplorerRootResolverTests -only-testing:cmuxTests/FileExplorerStoreTests -only-testing:cmuxTests/RemoteFileExplorerProviderTests -only-testing:cmuxTests/AppDelegateShortcutRoutingTests -only-testing:cmuxTests/SessionPersistenceTests -only-testing:cmuxTests/WorkspaceUnitTests test
- go test ./daemon/remote/cmd/cmuxd-remote -run 'TestHelloAdvertisesFSListCapability|TestFSList'
- gh workflow run test-e2e.yml --repo manaflow-ai/cmux -f ref=task-file-explorer-ssh-sidebar -f test_filter="FileExplorerSidebarUITests" -f record_video=true
- ./scripts/reload.sh --tag task-file-explorer-ssh-sidebar

## Issues
- Related: file explorer sidebar for local and SSH terminal roots, with nested root merging
```

- [ ] **Step 6: Post-merge cleanup**

```bash
cd /Users/lawrence/fun/cmuxterm-hq/repo
git worktree remove /Users/lawrence/fun/cmuxterm-hq/worktrees/task-file-explorer-ssh-sidebar
```

Plan complete and saved to `docs/superpowers/plans/2026-03-22-ssh-file-explorer-sidebar.md`. Ready to execute?
