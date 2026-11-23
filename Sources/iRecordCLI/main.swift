import Foundation
import iRecordCore

let arguments = CLIArgs(Array(CommandLine.arguments.dropFirst()))
CommandRunner.run(arguments)
