# Lineup

A macOS menu bar app for the work in front of you: your open Jira tickets by priority, your
meetings, and the notifications your tools post, in one panel.

- **List**: the tickets with a block in your calendar, soonest first, then the others, highest
  priority first. Check a ticket off (it moves to Done), raise or lower its priority, or take its
  block out of the calendar.
- **Agenda**: today and the next days, from your calendars, with a button to join the video
  call.
- **Plan with Claude** (`⌘P`, or ✨ on a ticket): Claude proposes a slot and a duration for
  each unscheduled ticket, highest priority first, around your meetings and inside your working
  hours. You review the proposals, untick the ones you do not want, pick the calendar, and
  apply: each becomes an event of its duration, titled with the ticket key and linking to it.
  The list then shows the ticket under "Dans l'agenda" until the block is over.
- **Search** (`⌘F`): narrows the list and the agenda to what matches every word typed.
  Type a ticket key of any project (`OPS-12`) to pin it to the list until it is closed.
- **Notifs**: an inbox any script, CI job, hook or agent posts to with `lineup-notify`, and
  that Claude reads and writes through a local MCP server. The menu bar shows how many are
  unread. See [Notifications](#notifications).
- **Quick add** (`⌘N`): a ticket in one of your projects. Add `@ 14h`, `@ demain 10h` or
  `@ 2026-10-22 09:00` to also block an hour for it in the calendar.

It talks to the tools you already use, signed in once:

| What | Through | Needs |
| --- | --- | --- |
| Search, create and close tickets | [`acli`](https://developer.atlassian.com/cloud/acli/) | `acli jira auth login` |
| Change a priority | Jira REST API | an API token in the Keychain (optional) |
| Agenda | macOS Calendar (EventKit) | your calendars added in Calendar; access granted on first launch |
| Planning | the `claude` CLI, print mode | Claude Code installed and signed in |
| Notifications | `~/.config/lineup/inbox.json` | nothing |

## Install

Requires macOS 14 and the Swift toolchain (Xcode or the Command Line Tools).

```bash
scripts/install.sh --open
```

This builds the app, installs it in `~/Applications/Lineup.app`, links
`~/.local/bin/lineup-notify` to the command line inside it, and launches it. To start it
at login, add it in System Settings › General › Login Items.

## Configure

The first launch writes `~/.config/lineup/config.json`; **Réglages** in the panel opens it.
Every key is optional:

| Key | Default | Meaning |
| --- | --- | --- |
| `jiraSite` | `https://your-site.atlassian.net` | Jira site, for links and REST calls |
| `jiraEmail` | `""` | Account for REST calls (priority changes) |
| `jql` | your open tickets | Tickets the list shows |
| `createProjects` | `[]` | Projects a quick add can create a ticket in |
| `issueType` | `Task` | Type of a created ticket |
| `doneStatus` | `Done` | Status a checked-off ticket moves to |
| `acliPath` | `/opt/homebrew/bin/acli` | Where `acli` is |
| `agendaDays` | `3` | Days the agenda shows |
| `refreshMinutes` | `5` | How often the panel refreshes |
| `workdayStart`, `workdayEnd` | `09:00`, `18:30` | Hours the planner fits tickets into, Monday to Friday |
| `planDays` | `5` | Days ahead the planner may use |
| `maxPlanned` | `8` | Most tickets one "plan everything" run takes |
| `planModel` | `sonnet` | Model the planner asks |
| `claudePath` | `~/.local/bin/claude` | Where the `claude` CLI is |

For example:

```json
{
  "jiraSite": "https://example.atlassian.net",
  "jiraEmail": "you@example.com",
  "jql": "project = TEAM AND statusCategory != Done ORDER BY priority DESC, created ASC",
  "createProjects": ["TEAM", "OPS"]
}
```

### Priority changes

`acli` cannot change a priority, so the ▲ ▼ buttons call the Jira REST API. They appear once
`jiraEmail` is set and an [API token](https://id.atlassian.com/manage-profile/security/api-tokens)
is in the Keychain:

```bash
security add-generic-password -s lineup -a you@example.com -w
```

### How planning works

The app runs `claude -p` with a system prompt of its own, no tools, no MCP server and no
settings, and asks for a structured answer validated against a JSON schema. Claude only sees
the tickets to plan (key, summary, priority, status), the busy slots of the coming days and the
working hours, which keeps a run around 1,500 tokens. The app then checks every proposal itself
(future, weekday, inside working hours, no overlap with a meeting, a block or another
proposal) and lists the ones it dropped and why. Nothing is written until you apply, and then only to the calendar you picked.

## Notifications

The inbox is one JSON file, `~/.config/lineup/inbox.json` (or `$LINEUP_INBOX`). The app,
the command line and the MCP server each change it under a lock, so any number of them can
post at once; the app shows a new notification within two seconds. It keeps the last 500, and
drops the read ones after 14 days.

### From a script

```bash
lineup-notify post "Pipeline main failed" --source ci --level error --url https://… --key main
lineup-notify post "Nightly export done" --body "12,408 rows" --source cron --level success
lineup-notify list            # unread; --all for every one, --json for the raw records
lineup-notify read --all      # or read ID…
lineup-notify dismiss --read  # or dismiss ID…
lineup-notify version         # the installed version
```

`--level` is `info` (the default), `success`, `warning` or `error`. A `--key` makes the posting
replace the earlier one of the same source and key, unread again: a job that reports on every
run leaves one notification, its latest.

### From Claude

`lineup-notify mcp` serves the inbox over MCP on stdin and stdout. It is local and has no
authentication: Claude Code starts it as a child process and nothing listens on the network.
Register it once for every project, from **Réglages › Installer le serveur MCP dans Claude
Code** in the panel, or from a terminal:

```bash
lineup-notify install-mcp
```

Both run `claude mcp add --scope user inbox` (the `claudePath` setting says where `claude` is),
replacing an earlier registration. The menu ticks the entry once Claude Code runs this
install's server, and shows the version installed; `lineup-notify version` prints it too.

Claude then has four tools:

| Tool | Does |
| --- | --- |
| `list_notifications` | The newest notifications, unread only by default, with the unread count; `source`, `limit` narrow it |
| `post_notification` | Posts one; `source` defaults to `claude` |
| `mark_read` | Marks `ids`, or `all: true` |
| `dismiss_notifications` | Removes `ids`, or every read one with `all: true` |

So "what's new in my inbox?" works in any session, and so does "tell me in the inbox when the
migration is done". To have Claude Code post on its own when it waits for you, a hook in
`~/.claude/settings.json` is enough:

```json
{
  "hooks": {
    "Notification": [
      { "hooks": [{ "type": "command", "command": "~/.local/bin/lineup-notify post \"Claude Code is waiting\" --source claude-code --key \"$CLAUDE_PROJECT_DIR\" --body \"$CLAUDE_PROJECT_DIR\"" }] }
    ]
  }
}
```

## Develop

```bash
swift build                  # build everything
swift run lineup-checks     # run the checks of LineupCore
swift run lineup-checks --live   # also ask the real claude to plan made-up tickets
swift run Lineup         # run the app without a bundle (no calendar access)
swift run lineup-notify list     # the inbox's command line
```

`LineupCore` holds everything testable: the models, the quick add parser, the configuration,
the `acli` and REST clients, and the inbox with its MCP server. `lineup-notify` is the
inbox's command line. `Lineup` is the SwiftUI app. The checks are a
plain executable because XCTest and Swift Testing both need Xcode.

## License

[MIT](LICENSE)
