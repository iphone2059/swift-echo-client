import CECClientCore
import Foundation
import WinSDK

@main struct SwiftEchoClient {
  static func writeUsage(_ handle: FileHandle) {
    handle.write(Data(cecUsageText.utf8))
  }

  static func help() { writeUsage(.standardOutput) }

  static func usageError() { writeUsage(.standardError) }
  static func run() -> CECExitCode {
    let args: [[UInt16]]
    do { args = try cecWindowsArguments() } catch {
      cecReport(stage: error.stage, error: error.code)
      return .internalFailure
    }
    let options: CECOptions
    do { options = try cecParseOptions(args) } catch {
      FileHandle.standardError.write(Data("Invalid arguments: \(error.message)\n".utf8))
      usageError()
      return .usage
    }
    if options.help {
      help()
      return .success
    }
    let control = CECSharedControl()
    do {
      let registration = try CECConsoleRegistration(control: control)
      let result = cecRunClient(options: options, control: control)
      registration.keepAlive()
      return result
    } catch {
      cecReport(stage: error.stage, error: error.code)
      return .internalFailure
    }
  }
  static func main() { ExitProcess(UInt32(run().rawValue)) }
}