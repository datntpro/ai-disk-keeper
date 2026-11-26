import Foundation

/// Verbatim one-line renderings of a command. Shell quoting is for DISPLAY only: nothing is ever run through a shell.
public enum ToolCommandDisplay {
    /// `docker image rm sha256:…`: the executable's name, then the argv.
    public static func line(_ snapshot: ToolCommandSnapshot) -> String {
        let name = (snapshot.executablePath as NSString).lastPathComponent
        return ([name] + snapshot.argv).map(quote).joined(separator: " ")
    }

    /// The command a not-yet-planned item declares (blocked rows, the detail pane): display only, never run.
    public static func line(command: String, arguments: [String]) -> String {
        ([command] + arguments).map(quote).joined(separator: " ")
    }

    /// With the executable's absolute path and the tool-specific environment (`DOCKER_HOST=…`), for a tooltip.
    public static func fullLine(_ snapshot: ToolCommandSnapshot) -> String {
        let base: Set<String> = ["PATH", "LC_ALL", "HOME"]
        let env = snapshot.environmentDisplay.filter { !base.contains($0.key) }.sorted { $0.key < $1.key }
            .map { "\($0.key)=\(quote($0.value))" }
        return (env + snapshot.command.map(quote)).joined(separator: " ")
    }

    static func quote(_ s: String) -> String {
        let safe = s.utf8.allSatisfy { b in
            (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) || "_@%+=:,./-".utf8.contains(b)
        }
        if !s.isEmpty && safe { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
