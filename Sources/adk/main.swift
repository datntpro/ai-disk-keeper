import DiskKeeperCore
import Foundation

// `adk status`: reads the status file AI Disk Keeper publishes. Thin: all logic is in HostStatusCLI. It never starts the app.
let environment = PathEnvironment.current()
let result = HostStatusCLI.run(
    args: Array(CommandLine.arguments.dropFirst()),
    statusURL: HostStatusWriter.defaultFileURL(environment: environment), now: Date())
FileHandle.standardOutput.write(Data(result.stdout.utf8))
FileHandle.standardError.write(Data(result.stderr.utf8))
exit(result.exitCode)
