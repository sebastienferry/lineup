# Changelog

All notable changes to this project are documented in this file. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Hide a ticket from the list (👁 barré on hover): it leaves both sections and is never offered
  to the planner, until shown again from the folded "Masqués" section at the bottom.

### Fixed

- `install.sh` builds with the Command Line Tools alone on macOS 27, whose SDK needs Xcode's
  SwiftUI macros: it falls back to the newest macOS 26 SDK.

### Removed

- Reminders: Lineup no longer reads or writes reminders. The list shows the tickets with a
  block in the calendar, then the others; the agenda shows the calendar alone; the
  setting for the reminders command line is gone.

### Changed

- Quick add creates tickets only; an `@` time blocks an hour for the new ticket in the chosen
  calendar.

## [0.7.0] - 2026-10-22

### Added

- Notifications: a generic inbox that scripts, CI jobs and hooks post to with the new
  `lineup-notify` command line, shown in a "Notifs" view with the unread count in the menu bar.
  Open a notification's link, mark it read, or dismiss it.
- `lineup-notify mcp`, a local stdio MCP server with no authentication, through which Claude
  lists, posts, marks read and dismisses notifications.
- `install.sh` puts `lineup-notify` in the app bundle and links it from `~/.local/bin`.
- The "Réglages" button is a menu: the installed version, the settings, and the MCP server's
  registration with Claude Code, ticked once done; `lineup-notify install-mcp` and
  `lineup-notify version` do the same from a terminal.

### Changed

- Ticket keys show as blue pills, easier to spot and to click than a plain link.
- The panel is opaque, so the windows behind it no longer show through the rows.

## [0.6.0] - 2026-10-22

### Changed

- BacklogBar is now called Lineup: the app is `Lineup.app`, the settings live in
  `~/.config/lineup` (moved there from `~/.config/backlogbar` on first launch) and the Jira token
  is read under the Keychain service `lineup`, the old `backlogbar` one still accepted.

## [0.5.1] - 2026-10-21

### Fixed

- Ticket keys show in the link colour, underlined with a hand cursor on hover, instead of plain
  grey text.

## [0.5.0] - 2026-10-20

### Changed

- Applying a plan adds an event of the proposed duration to a calendar chosen in the plan
  review, instead of a reminder.

### Added

- "Dans l'agenda" section: the tickets with an upcoming block in the calendar, with a button to
  take the block out.

## [0.4.0] - 2026-10-20

### Added

- Pin a ticket of any project to the list: type its key in the search and pick "Épingler"; it
  stays until unpinned or closed.

### Changed

- Tickets on the older priority scheme (Blocker to Trivial) sort, show and step alongside the
  default one (Highest to Lowest).

## [0.3.0] - 2026-10-20

### Added

- Search bar (`⌘F`) filtering the list and the agenda by ticket key, title, status, priority,
  reminder or meeting title, ignoring case and accents.
- The plan review names the calendar the planned reminders were copied into.

## [0.2.0] - 2026-10-20

### Added

- Plan with Claude: proposes a slot and a duration for the unscheduled tickets, or for one
  ticket, around meetings and inside working hours; the proposals are reviewed before they
  become reminders.

## [0.1.0] - 2026-10-20

### Added

- Menu bar panel listing scheduled reminders and the open Jira tickets no reminder names yet,
  highest priority first.
- Check a ticket off, change its priority, or plan it for tomorrow; check a reminder off or push
  it back an hour or a day.
- Agenda of today and the next days, from macOS Calendar, with reminders alongside meetings.
- Quick add of a reminder or of a ticket in a configured project, with an optional `@` time.
