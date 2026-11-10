# BackgroundMemo

A macOS notepad that lives on the desktop, under your other windows, with the wallpaper showing through.

- Memo tabs with terminal-style splits and rich text
- A daily planner in 10-minute slots; drag an entry to turn it into a time range
- A to-do list
- The class timetable for Daedeok Software Meister High School, grade 1 class 1, from the official NEIS API
- The school's breakfast, lunch, and dinner menu for any day, also from NEIS

The school, class, and bell times are fixed in the code for now.

## Install

Requires macOS 26 or later on Apple Silicon.

1. Download the zip from [Releases](../../releases) and move `BackgroundMemo.app` to Applications.
2. Open the app. macOS blocks the first launch because the app is not notarized.
3. Open System Settings > Privacy & Security and choose **Open Anyway**.

To start it at login, enable **로그인 시 자동 실행** in the BackgroundMemo menu.

## NEIS API key

Without a key, the planner shows periods 1 to 5. To see every period, get a free key from [open.neis.go.kr](https://open.neis.go.kr) and enter it under 파일 > NEIS 인증키 입력…. The key is stored only on your Mac. The meal tab works without a key; it uses the same key when one is entered.

## Build from source

Requires Swift 6.

```sh
./scripts/build-app.sh
swift run CoreChecks
```
