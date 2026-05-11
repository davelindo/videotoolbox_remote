import Foundation
import VTRemotedCore

let args = Arguments.parse(CommandLine.arguments)

if !args.parseError.isEmpty {
    let message = "error: \(args.parseError)\n\n\(Arguments.usage)\n"
    FileHandle.standardError.write(Data(message.utf8))
    exit(2)
}

if args.showHelp {
    print(Arguments.usage)
    exit(0)
}

if args.showVersion {
    print("vtremoted \(Arguments.version)")
    exit(0)
}

Logger.shared.level = args.logLevel

VideoToolboxPreflight.checkOrExit()

do {
    let server = VTRServer(arguments: args)
    try server.run()
} catch {
    Logger.shared.error("FATAL: \(error)")
    exit(1)
}
