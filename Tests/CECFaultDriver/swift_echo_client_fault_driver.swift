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
    case "e2e_missing_completion", "e2e_cancel_positive":
      guard let port = UInt16(CommandLine.arguments.dropFirst(2).first ?? "") else {
        ExitProcess(1)
      }
      cecExerciseRealCancelledCompletion(
        port: port, hide: CommandLine.arguments[1] == "e2e_missing_completion")
    case "missing_rio_completion": cecExerciseMissingCompletion(positive: false, connect: false)
    case "missing_connect_completion": cecExerciseMissingCompletion(positive: false, connect: true)
    case "drain_rio_positive": cecExerciseMissingCompletion(positive: true, connect: false)
    case "drain_connect_positive": cecExerciseMissingCompletion(positive: true, connect: true)
    case "worker_slot_ownership": cecExerciseSlotOwnership()
    case "worker_not_started": cecExerciseReleaseBoundary(positive: false, stackOrder: false)
    case "worker_release_order": cecExerciseReleaseBoundary(positive: false, stackOrder: true)
    case "worker_release_positive": cecExerciseReleaseBoundary(positive: true, stackOrder: false)
    case "aggregate_deinit_positive", "worker_deinit", "transport_deinit", "resources_deinit",
      "worker_deinit_unjoined":
      cecExerciseAggregateDeinit(mode: CommandLine.arguments[1])
    case "timer_resolution_positive", "timer_resolution_failure":
      ExitProcess(
        UInt32(
          cecExerciseTimerResolution(
            positive: CommandLine.arguments[1] == "timer_resolution_positive"
          ).rawValue))
    case "join_barrier_failure": cecExerciseJoinBarrier(positive: false)
    case "join_barrier_positive": cecExerciseJoinBarrier(positive: true)
    case "stale_generation", "duplicate_operation", "posted_extent", "socket_identity",
      "operation_positive", "send_offset_underflow", "send_extent_positive":
      cecExerciseOperationFault(mode: CommandLine.arguments[1])
    case "config_layout": print("configuration_bytes=\(MemoryLayout<CECWorkerConfiguration>.size)")
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
