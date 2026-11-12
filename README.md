# BackgroundMemo

English | [한국어](README.ko.md)

A macOS notepad that lives on the desktop, under your other windows, with the wallpaper showing through.

- Memo tabs with terminal-style splits and rich text
- A daily planner in 10-minute slots; drag an entry to turn it into a time range
- A to-do list
- Your class timetable, placed in the planner by your school's bell times, from the official NEIS API
- Your school's breakfast, lunch, and dinner menu for any day, also from NEIS

Elementary, middle, and high schools are supported. Special schools are looked up through the high school timetable, which may not list them.

## Install

Requires macOS 26 or later on Apple Silicon.

1. Download the zip from [Releases](../../releases) and move `BackgroundMemo.app` to Applications.
2. Open the app. macOS blocks the first launch because the app is not notarized.
3. Open System Settings > Privacy & Security and choose **Open Anyway**.

Clicking the memo or its Dock icon brings it in front of other windows until you switch to another app. To keep it on the desktop at all times, turn off **클릭하면 맨 앞으로** in the BackgroundMemo menu.

To start it at login, enable **로그인 시 자동 실행** in the BackgroundMemo menu.

## Choose your school

On first launch the **학교 설정** window opens. Search for your school by name, pick it from the list, and choose your grade and class. The bell times are filled in for the school you pick (09:00 start, 50-minute classes, 10-minute breaks, and a 60-minute lunch after period 4); change, add, or remove periods to match your school. Open the window again any time with BackgroundMemo > 학교 설정… (⌘,).

If you close the window without saving, the planner, to-do list, and memos work as usual, and the timetable and meals stay empty until a school is set.

Installs from before this setting existed keep Daedeok Software Meister High School, grade 1 class 1, and its bell times.

## NEIS API key

Without a key, the planner shows periods 1 to 5 and school search shows at most 5 schools; type a more exact name if yours is not listed. To lift both limits, get a free key from [open.neis.go.kr](https://open.neis.go.kr) and enter it under 파일 > NEIS 인증키 입력…. The key is stored only on your Mac. The meal tab works without a key; it uses the same key when one is entered.

## Build from source

Requires Swift 6.

```sh
./scripts/build-app.sh
swift run CoreChecks
```
