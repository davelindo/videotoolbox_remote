import Foundation
import VTRemotedCore

let args = Arguments.parse(CommandLine.arguments)
Logger.shared.level = args.logLevel

VideoToolboxPreflight.checkOrExit()

do {
    let server = VTRServer(arguments: args)
    try server.run()
} catch {
    Logger.shared.error("FATAL: \(error)")
    exit(1)
}
