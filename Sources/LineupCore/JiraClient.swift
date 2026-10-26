import Foundation

/// Jira, through Atlassian's `acli` (already signed in, no token to manage) for searching,
/// creating and closing tickets, and through the REST API for the one thing `acli` cannot do:
/// changing a priority. The REST calls need an API token, kept in the macOS Keychain.
public struct JiraClient: Sendable {
    let config: Config
    let runner: CommandRunner

    public init(config: Config, runner: CommandRunner = ProcessRunner()) {
        self.config = config
        self.runner = runner
    }

    public func search() async throws -> [Ticket] {
        try await search(jql: config.jql)
    }

    /// The pinned tickets that are still open. A key that no longer exists makes Jira refuse
    /// the whole query, so the keys are checked one by one when pinned (`ticket(key:)`).
    public func openTickets(keys: [String]) async throws -> [Ticket] {
        guard !keys.isEmpty else { return [] }
        return try await search(jql: "key in (\(keys.joined(separator: ", "))) AND statusCategory != Done")
    }

    /// One ticket, open or not, or an error when it does not exist.
    public func ticket(key: String) async throws -> Ticket {
        guard let ticket = try await search(jql: "key = \(key)").first else { throw ShellError("\(key) : ticket introuvable") }
        return ticket
    }

    func search(jql: String) async throws -> [Ticket] {
        let json = try await runner.output(config.acliPath, [
            "jira", "workitem", "search",
            "--jql", jql,
            // acli refuses "created" among the fields.
            "--fields", "key,summary,priority,status",
            "--limit", "200",
            "--json",
        ])
        return try Self.parseTickets(json)
    }

    /// Creates a ticket and answers its key.
    public func create(project: String, summary: String) async throws -> String {
        let output = try await runner.output(config.acliPath, [
            "jira", "workitem", "create",
            "--project", project,
            "--type", config.issueType,
            "--summary", summary,
            "--json",
        ])
        guard let key = firstTicketKey(in: output, projects: [project]) else {
            throw ShellError("Jira did not return the new ticket's key: \(output.prefix(160))")
        }
        return key
    }

    public func close(key: String) async throws {
        _ = try await runner.output(config.acliPath, [
            "jira", "workitem", "transition", "--key", key, "--status", config.doneStatus, "--yes",
        ])
    }

    /// Whether priority changes are possible: an e-mail in the config and a token in the Keychain.
    public var canChangePriority: Bool {
        !config.jiraEmail.isEmpty && Keychain.token(account: config.jiraEmail) != nil
    }

    public func setPriority(key: String, priority: String) async throws {
        guard let token = Keychain.token(account: config.jiraEmail), !config.jiraEmail.isEmpty else {
            throw ShellError("no Jira API token in the Keychain for \(config.jiraEmail)")
        }
        let site = config.jiraSite.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(site)/rest/api/3/issue/\(key)") else { throw ShellError("bad Jira site URL") }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let basic = Data("\(config.jiraEmail):\(token)".utf8).base64EncodedString()
        request.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["fields": ["priority": ["name": priority]]])
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw ShellError("Jira refused the priority change (HTTP \(status)): \(String(decoding: data.prefix(160), as: UTF8.self))")
        }
    }

    struct Issue: Decodable {
        struct Fields: Decodable {
            struct Named: Decodable { let name: String? }
            let summary: String?
            let priority: Named?
            let status: Named?
            let created: String?
        }
        let key: String
        let fields: Fields
    }

    static func parseTickets(_ json: String) throws -> [Ticket] {
        let issues = try JSONDecoder().decode([Issue].self, from: Data(json.utf8))
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return issues.map { issue in
            // Jira writes "+0200" offsets, which ISO8601DateFormatter reads once given a colon.
            let created = issue.fields.created.flatMap { raw -> Date? in
                let fixed = raw.replacingOccurrences(of: #"([+-]\d{2})(\d{2})$"#, with: "$1:$2", options: .regularExpression)
                return formatter.date(from: fixed)
            }
            return Ticket(
                key: issue.key,
                summary: issue.fields.summary ?? "",
                priority: issue.fields.priority?.name ?? "Medium",
                status: issue.fields.status?.name ?? "",
                created: created
            )
        }
    }
}

/// The Jira API token, read with the `security` tool so no entitlement is needed. Saved with
/// `security add-generic-password -s lineup -a <email> -w <token>`.
public enum Keychain {
    public static let service = "lineup"
    /// The service the token was saved under when Lineup was called BacklogBar.
    static let legacyService = "backlogbar"

    public static func token(account: String) -> String? {
        token(service: service, account: account) ?? token(service: legacyService, account: account)
    }

    static func token(service: String, account: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", service, "-a", account, "-w"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let token = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return process.terminationStatus == 0 && !token.isEmpty ? token : nil
    }
}
