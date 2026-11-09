# BackgroundMemo Design

## Goal

A native macOS notepad that feels like part of the wallpaper. macOS Stickies covers the wallpaper with opaque notes; BackgroundMemo is one Liquid Glass window that lets the wallpaper show through, with terminal-style tabs and splits and Stickies-style text formatting.

Success means the author can keep it on the desktop every day: it stays behind other apps, accepts clicks and Korean input reliably, stays legible on real wallpapers, and restores everything after a relaunch.

## Decisions

| Topic | Decision |
|---|---|
| Platform | Native macOS `.app`, minimum macOS 26 |
| Stack | Swift, AppKit-first, SwiftUI only for a settings screen if one is needed |
| Build | Swift Package plus a script that assembles the `.app` (Xcode is not installed) |
| Window | One borderless window |
| Layer | Above desktop icons, below normal app windows; never comes forward |
| Spaces | Visible on all desktops; not shown over full-screen apps |
| Displays | Shown on one display in v1 |
| Material | Liquid Glass, matching the reference: clear wallpaper show-through, thin bright edge, rounded corners, pill tab bar |
| Layout | Tabs contain splits (iTerm2 model), one tab bar |
| Formatting | Native Font menu, color panel, and shortcuts; pasted images |
| Storage | RTFD, one document per split pane |
| Launch | Starts at login; keeps its Dock icon because the Font menu needs the menu bar |

## Out of scope for v1

Always-on-top or hotkey summon, separate notes per Space, multiple displays, Markdown import or export, sync, and App Store distribution.

## Window behavior

- The window sits one level above the desktop icon level and below normal windows. It covers any desktop icons beneath it, so clicks inside it never reach them.
- Collection behavior: joins all Spaces, stationary, excluded from window cycling.
- Dragging an empty part of the tab bar moves the window. Dragging an edge resizes it.
- Clicking activates the app and focuses the pane without raising the window.
- If saved bounds are off-screen after a display change, the window moves to a visible position.

## Interface

A pill-shaped tab bar sits at the top of the glass window, with `+` for a new tab. Panes are separated by thin dividers that can be dragged.

| Shortcut | Action |
|---|---|
| ⌘T | New tab |
| ⌘W | Close pane; closes the tab when it is the last pane |
| ⌘D | Split left and right |
| ⇧⌘D | Split top and bottom |
| ⌘[ / ⌘] | Previous / next pane |

Default text color is chosen for contrast against the glass. Dark text on a dark wallpaper is the main legibility risk, so glass clarity and text contrast are tuned on real wallpapers.

## Storage

```
~/Library/Application Support/BackgroundMemo/
├── workspace.json      window bounds, tab order, split tree and ratios
└── Documents/
    └── <UUID>.rtfd     one per pane, images included
```

- Autosave runs about one second after typing stops and again on quit.
- Writes are atomic, so a crash during a save leaves the previous version intact.
- A corrupt `workspace.json` is kept as a backup. Surviving documents reopen as tabs.
- Closing a pane moves its document to the Trash.
- A document that cannot be read shows an error in its pane and is never overwritten.

## Modules

| Module | Responsibility | Depends on | Owner |
|---|---|---|---|
| `WorkspaceModel` | Tab and split tree, JSON encoding, recovery | Foundation | Codex |
| `DocumentStore` | RTFD read and write, autosave, Trash | Foundation, AppKit attributed strings | Codex |
| `DesktopWindow` | Window level, Spaces, input, glass | AppKit | Claude |
| `TabBar`, `SplitContainer` | Tab and split views bound to the model | `WorkspaceModel` | Claude |
| `MemoTextView` | Rich text, Font menu, images, default color | AppKit, `DocumentStore` | Claude |

Codex runs with its workspace-write sandbox and changes only files inside this repository.

## Delivery order

1. **Prototype gate.** Build a desktop-level glass window with a text view. Verify clicking, typing, Korean IME composition, dragging, and glass rendering over the wallpaper. If the glass does not render at this layer, fall back to `NSVisualEffectView`. If input does not work, stop and revisit the layer decision with the author.
2. **Parallel build** of the modules above.
3. **Cross-review.** Unit tests cover `WorkspaceModel` and `DocumentStore`. Claude and Codex review each other's modules.
4. **Run check.** Build the `.app` and verify it on the real desktop. The author judges the glass and contrast.

Work lands on branches and is pushed to the private GitHub repository `backgroundmemo` as it progresses.

## Testing

- Model: split, close, tab reorder, JSON round trip, corrupt JSON recovery.
- Store: RTFD round trip with formatting and an image, atomic save, Trash on close, unreadable document preserved.
- Manual: the prototype gate checks, relaunch restore, switching Spaces, Mission Control, display change.

## Planner and to-do tabs

Two fixed tabs sit in the tab bar alongside memo tabs: `계획` and `할 일`. Exactly one of each exists; they cannot be closed or split, but they can be reordered. Files saved before these tabs existed gain them on load, keeping existing memos.

- **Planner.** A date header with previous, next, and today controls above one editable row per hour from 06:00 to 23:00. It opens on today and follows the date across midnight when today is showing.
- **To-do.** One list independent of dates. Enter adds, a checkbox completes, completed items sink below open items, and items can be edited and deleted.
- **Storage.** `planner.json` and `todos.json` beside `workspace.json`, using atomic debounced saves. Failures retry and are reported at quit, as for documents. A corrupt file is kept as a backup. An unreadable file is never overwritten.

## School timetable

The planner shows one class's timetable between the date header and the hour rows. It uses the official NEIS Open API (`hisTimetable`). 컴시간 is not used because it has no official API and its data calls are encrypted.

- **Requests.** One day at a time, never on weekends, and at most one successful fetch per day per session. Without an API key the request asks for 5 rows; it never pages or splits requests to get around that limit, and a day with more classes shows as partial. The API key is stored in an owner-only file (`neis-api-key`, mode 0600) in the app data folder, because an ad-hoc signed app triggers keychain password prompts after every rebuild.
- **Storage.** `timetable.json` beside `workspace.json`. Failed fetches never replace the cache. Cache save failures are logged and do not block quitting, because the data can be fetched again.
- **Display.** Read-only and separate from the planner's entries, which it never changes.
