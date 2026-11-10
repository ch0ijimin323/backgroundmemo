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
| Launch | Start at login is an opt-in app menu setting; keeps its Dock icon because the Font menu needs the menu bar |

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
├── school.json         school, grade, class, and bell times
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
- School settings: save round trip, unreadable and corrupt `school.json`, the old-install migration and new-install detection, timetable endpoint by school kind, default bell times, the school search parser (normal, INFO-200, more results, broken JSON), and cache clearing, in-flight results, and cache identity when settings change.
- Manual: the prototype gate checks, relaunch restore, switching Spaces, Mission Control, display change.

## Planner and to-do tabs

Three fixed tabs sit in the tab bar alongside memo tabs: `계획`, `할 일`, and `급식` (see School meals). Exactly one of each exists; they cannot be closed or split, but they can be reordered. Files saved before these tabs existed gain them on load, keeping existing memos.

- **Planner.** A date header with previous, next, and today controls above one editable row every 10 minutes from 06:00 through 05:50 the next morning. The planner day runs from 06:00 to 06:00, so late-night plans stay on the evening's page; the page turns at 06:00, not at midnight. Times sit on the row boundaries, so an entry covers its time up to the next one. It opens on today near the current time, and other days near the first period's start (08:40 when no school is set), and follows the date at 06:00 when today is showing. Entries are keyed by minutes from midnight; hour keys from older files convert on load, and no text is lost if a slot is already taken. Dragging down from a row with text (its bottom edge, its time, or the empty area after its text) makes a span: the rows get the same band as a class, the text stays on the first row, and the other rows cannot be edited. A span ends before the next row with text and at 23:50, can overlap a class, and goes away when dragged back to its first row or when that row is cleared.
- **To-do.** One list independent of dates. Enter adds, a checkbox completes, completed items sink below open items, and items can be edited and deleted.
- **Storage.** `planner.json` and `todos.json` beside `workspace.json`, using atomic debounced saves. Failures retry and are reported at quit, as for documents. A corrupt file is kept as a backup. An unreadable file is never overwritten.

## School settings

The timetable and meals are for the school, grade, and class the user sets; nothing about the school is fixed in the code.

- **Settings.** `school.json` beside `workspace.json` holds the NEIS office code (`ATPT_OFCDC_SC_CODE`), school code (`SD_SCHUL_CODE`), school name, school kind (elementary, middle, high, or other), grade, class (`CLASS_NM` exactly as entered, so `1` and `가` both work), each period's start time in minutes, and one class length. It is written atomically. A corrupt file is kept as a backup and the settings window opens; an unreadable file is never overwritten, and settings saved while it is unreadable apply only for that session.
- **First launch.** The settings are read before the workspace, because loading the workspace creates `workspace.json`. With neither file, it is a new install and the settings window opens after launch. With `workspace.json` but no `school.json`, it is an install from before settings existed: `school.json` is written with 대덕소프트웨어마이스터고 (G10, 7430310) grade 1 class 1, bell times 08:40, 09:40, 10:40, 11:40, 13:30, 14:30, 15:30, 16:20, and 50-minute classes, and no window opens.
- **No school.** Until a school is set, the planner and meal tabs show `학교를 설정하면 시간표가 표시됩니다` (or `…급식이 표시됩니다`) under the header and request nothing. Plans, to-dos, and memos work as usual.
- **Window.** BackgroundMemo > `학교 설정…` (⌘,) opens a normal titled window, which sits above the desktop-level memo window. It has a school name search field with a search button (Return also searches), a result list showing name · kind · region, a grade menu (1–6 for elementary and other schools, 1–3 for middle and high), a class field, the period start times as HH:mm with add and delete, the class length, and a note on the NEIS key and the `NEIS 인증키 입력…` menu. Choosing a school fills in its default bell times. Save stays disabled until a school and class are set and every time is valid; the reason shows beside it. Cancel or closing the window keeps the previous settings.
- **Korean input.** Return in the search field searches after the key event finishes, reading the field once; a Return that only commits a composition does not search, and the same name is not searched twice at once.
- **Default bell times.** 대덕소프트웨어마이스터고 uses the times above. Any other school gets 09:00, 10:00, 11:00, 12:00, then lunch for 60 minutes in place of the break after period 4, then 13:50, 14:50, 15:50, 16:50: 50-minute classes and 10-minute breaks through period 8.
- **School search.** `https://open.neis.go.kr/hub/schoolInfo?Type=json&pIndex=1&pSize=N&SCHUL_NM=<name>`, with `KEY` when one is entered. N is 5 without a key and 100 with one. Only the first page is requested. When the API holds more matches than it returned, the window says `결과가 더 있습니다. 학교 이름을 더 정확히 입력하세요`. Rows give `SCHUL_NM`, `SCHUL_KND_SC_NM`, `ATPT_OFCDC_SC_CODE`, `SD_SCHUL_CODE`, and `LCTN_SC_NM`; a row without a name or code is skipped. INFO-200 is no match, and other result codes, HTTP errors, network errors, and broken JSON show a failure.
- **Changing settings.** A different class (office, school, kind, grade, or class) empties `timetable.json`, forgets the session's fetched and failed days, and discards requests in flight; a different school does the same for `meals.json`. Meals are per school, so a new grade or class at the same school keeps them, and new bell times alone keep both caches because the fetched data is the same. The shown day is then requested again.
- **Cache identity.** Each cache file records the class or school it holds. A cache for other settings is ignored when read and replaced by the next successful fetch. Files written before settings existed belong to 대덕소프트웨어마이스터고 grade 1 class 1.

## School timetable

The planner shows the configured class's timetable inside its 10-minute rows, placed by the configured bell schedule. It uses the official NEIS Open API: `hisTimetable` for high schools, `misTimetable` for middle schools, `elsTimetable` for elementary schools, and `hisTimetable` for other kinds, where a failure adds a note that the school may not be listed. 컴시간 is not used because it has no official API and its data calls are encrypted.

- **Requests.** One day at a time, never on weekends, and at most one successful fetch per day per session. Without an API key the request asks for 5 rows; it never pages or splits requests to get around that limit, and a day with more classes shows as partial. The API key is stored in an owner-only file (`neis-api-key`, mode 0600) in the app data folder, because an ad-hoc signed app triggers keychain password prompts after every rebuild.
- **Storage.** `timetable.json` beside `workspace.json`. Failed fetches never replace the cache. Cache save failures are logged and do not block quitting, because the data can be fetched again.
- **Display.** Each class spans the slots within its class length from its start time under a faint band, and its first slot shows a label such as `1교시 공통수학2`; a start between slots, such as 08:45, is labeled on the first slot inside the class. Periods with no bell time are not placed. Days other than today open near the first period's start. Rows stay editable, classes never change the planner's entries, and one line under the header appears only while loading, after a failure, or when the day is partial.

## School meals

The `급식` fixed tab shows one day's school meals from the NEIS Open API (`mealServiceDietInfo`, the same for every kind of school), for the configured school. It follows the fixed tab rules above; a file saved before it existed gains it after its last fixed tab, keeping every other tab and memo.

- **Requests.** One calendar day at a time with 5 rows (a day has at most three meals, so this is enough with or without a key), weekends included, and at most one successful fetch per day per session. A failed day waits 30 seconds before it is requested again. The NEIS key is used when one is entered and never appears in logs.
- **Parsing.** `DDISH_NM` is split on `<br/>`. Each dish loses its trailing allergy numbers such as `(1.2.5)`, keeps any other parentheses such as `(대)`, and has its spaces tidied; empty dishes are dropped. `MMEAL_SC_CODE` 1, 2, and 3 are 조식, 중식, and 석식; other codes are ignored, and the first row wins when a meal repeats. `CAL_INFO` is kept as sent. INFO-200 is a day without meals. Any other result code, broken JSON, or a row for another date or without a date is a failure.
- **Storage.** `meals.json` beside `workspace.json`, with the timetable's rules: failures never replace the cache, an unreadable file is never overwritten, save failures are logged and do not block quitting, and a cache for another school is ignored.
- **Display.** A date header like the planner's, but on calendar dates: `오늘` and the midnight page turn follow the calendar day, not the planner's 06:00 day. Below it, 조식, 중식, and 석식 stack vertically, each on a faint rounded band with its calories beside the title and one dish per line, or `급식 없음`. The content scrolls when it overflows and cannot be edited. One line under the header appears only while loading or after a failure, when any cached meals stay visible.
