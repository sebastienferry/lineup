import Foundation

/// Settings, read from `~/.config/lineup/config.json`. Every key is optional: a missing one
/// takes its default, so the file only holds what differs.
public struct Config: Codable, Equatable, Sendable {
    /// The Jira site, for links and for the REST calls `acli` cannot make.
    public var jiraSite: String
    /// The account the REST calls authenticate as, with an API token kept in the Keychain.
    public var jiraEmail: String
    /// The tickets the list shows.
    public var jql: String
    /// The projects a quick add can create a ticket in, in the order the picker shows them.
    public var createProjects: [String]
    /// The type of a ticket created by a quick add.
    public var issueType: String
    /// The status a ticket moves to when it is checked off.
    public var doneStatus: String
    public var acliPath: String
    /// Days the agenda shows, today included.
    public var agendaDays: Int
    public var refreshMinutes: Int
    /// Working hours the planner fits tickets into, "HH:MM", Monday to Friday.
    public var workdayStart: String
    public var workdayEnd: String
    /// Days ahead the planner may use, today included.
    public var planDays: Int
    /// The most tickets one "plan everything" run takes, highest priority first.
    public var maxPlanned: Int
    /// The model the planner asks, as `claude --model` takes it.
    public var planModel: String
    /// The `claude` command line; a leading "~" is the home directory.
    public var claudePath: String

    public static let defaults = Config(
        jiraSite: "https://your-site.atlassian.net",
        jiraEmail: "",
        jql: "assignee = currentUser() AND statusCategory != Done ORDER BY priority DESC, created ASC",
        createProjects: [],
        issueType: "Task",
        doneStatus: "Done",
        acliPath: "/opt/homebrew/bin/acli",
        agendaDays: 3,
        refreshMinutes: 5,
        workdayStart: "09:00",
        workdayEnd: "18:30",
        planDays: 5,
        maxPlanned: 8,
        planModel: "sonnet",
        claudePath: "~/.local/bin/claude"
    )

    public init(
        jiraSite: String, jiraEmail: String, jql: String, createProjects: [String], issueType: String,
        doneStatus: String, acliPath: String, agendaDays: Int, refreshMinutes: Int,
        workdayStart: String, workdayEnd: String, planDays: Int, maxPlanned: Int, planModel: String, claudePath: String
    ) {
        self.jiraSite = jiraSite
        self.jiraEmail = jiraEmail
        self.jql = jql
        self.createProjects = createProjects
        self.issueType = issueType
        self.doneStatus = doneStatus
        self.acliPath = acliPath
        self.agendaDays = agendaDays
        self.refreshMinutes = refreshMinutes
        self.workdayStart = workdayStart
        self.workdayEnd = workdayEnd
        self.planDays = planDays
        self.maxPlanned = maxPlanned
        self.planModel = planModel
        self.claudePath = claudePath
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config.defaults
        jiraSite = try c.decodeIfPresent(String.self, forKey: .jiraSite) ?? d.jiraSite
        jiraEmail = try c.decodeIfPresent(String.self, forKey: .jiraEmail) ?? d.jiraEmail
        jql = try c.decodeIfPresent(String.self, forKey: .jql) ?? d.jql
        createProjects = try c.decodeIfPresent([String].self, forKey: .createProjects) ?? d.createProjects
        issueType = try c.decodeIfPresent(String.self, forKey: .issueType) ?? d.issueType
        doneStatus = try c.decodeIfPresent(String.self, forKey: .doneStatus) ?? d.doneStatus
        acliPath = try c.decodeIfPresent(String.self, forKey: .acliPath) ?? d.acliPath
        agendaDays = try c.decodeIfPresent(Int.self, forKey: .agendaDays) ?? d.agendaDays
        refreshMinutes = try c.decodeIfPresent(Int.self, forKey: .refreshMinutes) ?? d.refreshMinutes
        workdayStart = try c.decodeIfPresent(String.self, forKey: .workdayStart) ?? d.workdayStart
        workdayEnd = try c.decodeIfPresent(String.self, forKey: .workdayEnd) ?? d.workdayEnd
        planDays = try c.decodeIfPresent(Int.self, forKey: .planDays) ?? d.planDays
        maxPlanned = try c.decodeIfPresent(Int.self, forKey: .maxPlanned) ?? d.maxPlanned
        planModel = try c.decodeIfPresent(String.self, forKey: .planModel) ?? d.planModel
        claudePath = try c.decodeIfPresent(String.self, forKey: .claudePath) ?? d.claudePath
    }

    /// `claudePath` with a leading "~" expanded.
    public var resolvedClaudePath: String { (claudePath as NSString).expandingTildeInPath }

    /// The projects ticket keys are recognised in: the ones a ticket can be created in, plus the
    /// ones the JQL names with `project = X` or `project in (X, Y)`.
    public var knownProjects: [String] {
        var projects = createProjects
        let patterns = [#"project\s*=\s*"?([A-Z][A-Z0-9_]+)"#, #"project\s+in\s*\(([^)]*)\)"#]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
            for match in regex.matches(in: jql, range: NSRange(jql.startIndex..., in: jql)) {
                guard let range = Range(match.range(at: 1), in: jql) else { continue }
                for raw in jql[range].split(separator: ",") {
                    let key = raw.trimmingCharacters(in: CharacterSet(charactersIn: " \"'")).uppercased()
                    if !key.isEmpty, !projects.contains(key) { projects.append(key) }
                }
            }
        }
        return projects
    }

    public static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/lineup/config.json")
    }

    /// The saved settings, or the defaults written to disk on first run so they can be edited.
    public static func load(from url: URL = fileURL) -> Config {
        if url == fileURL { migrateLegacyFolder() }
        if let data = try? Data(contentsOf: url), let config = try? JSONDecoder().decode(Config.self, from: data) {
            return config
        }
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try? encoder.encode(defaults).write(to: url)
        }
        return defaults
    }

    /// Lineup was called BacklogBar: its settings and pins move to the new folder on first run.
    static func migrateLegacyFolder() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let legacy = home.appendingPathComponent(".config/backlogbar")
        let current = home.appendingPathComponent(".config/lineup")
        let manager = FileManager.default
        guard manager.fileExists(atPath: legacy.path), !manager.fileExists(atPath: current.path) else { return }
        try? manager.moveItem(at: legacy, to: current)
    }

    public func browseURL(for key: String) -> URL? {
        URL(string: "\(jiraSite.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/browse/\(key)")
    }
}
