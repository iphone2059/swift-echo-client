import CECClientCore
import Foundation
import WinSDK

@main struct SwiftEchoClient {
  static func help() {
    print(
      """
      Usage: swift-echo-client target /p tcp|udp [/r port] [/l port] [/n count]
             [/t seconds] [/i ms] [/d text | /z bytes | /zt bytes] [/k tcp-depth]
             [/c sessions] [/threads workers] [/w seconds] [/rc [seconds]]
             [/report seconds] [/b bytes] [/cq capacity] [/memory bytes] [/q] [/stats]
      Data I/O is always RIO; CQ notification is always IOCP. No fallback backend exists.
      """)
  }
  static func run() -> CECExitCode {
    let args: [[UInt16]]
    do { args = try cecWindowsArguments() } catch {
      cecReport(stage: error.stage, error: error.code)
      return .internalFailure
    }
    let options: CECOptions
    do { options = try cecParseOptions(args) } catch {
      FileHandle.standardError.write(Data("Invalid arguments: \(error.message)\n".utf8))
      help()
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
