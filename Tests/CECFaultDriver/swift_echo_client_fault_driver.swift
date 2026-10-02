import CECClientCore
import WinSDK

@main struct FaultDriver {
  static func main() {
    switch CommandLine.arguments.dropFirst().first ?? "normal" {
    case "console_stop":
      let args = CommandLine.arguments
      guard args.count == 5, let port = UInt16(args[3]) else { ExitProcess(1) }
      ExitProcess(
        UInt32(cecExerciseConsoleStop(clientPath: args[2], port: port, readyName: args[4]).rawValue)
      )
    case "shutdown_stop_race": cecExerciseShutdownStopRace()
    case "completion_range": cecExerciseInvalidCompletionContext(identity: false)
    case "completion_identity": cecExerciseInvalidCompletionContext(identity: true)
    case "partial_startup":
      ExitProcess(
        UInt32(
          cecExercisePartialStartupFailure(
            port: UInt16(CommandLine.arguments.dropFirst(2).first ?? "0") ?? 0
          ).rawValue))
    case "arena_capacity": ExitProcess(UInt32(cecExerciseArenaCapacity().rawValue))
    case "normal":
      cecRequireRIONotifySuccess(0, stage: "normal")
      _ = cecRequireValidDequeueCount(0, stage: "normal")
    case "notify_failure": cecRequireRIONotifySuccess(5, stage: "fault notify")
    case "corrupt_cq": _ = cecRequireValidDequeueCount(UInt32.max, stage: "fault CQ")
    case "notification_identity":
      cecRequireNotificationPacket(
        key: 1, overlapped: nil, expectedKey: 0, expectedOverlapped: nil, stage: "fault identity")
    case "outstanding_underflow": cecRequireOutstanding(0, stage: "fault outstanding")
    case "control_post_failure":
      cecRequireControlPostSuccess(false, error: 6, stage: "fault control")
    default: ExitProcess(1)
    }
  }
}
