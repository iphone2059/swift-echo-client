import Testing
import WinSDK

@testable import CECClientCore

@Suite struct CECEngineInternalTests {
  @Test func releaseAndNotifications() {
    var life = CECWorkerLifecycle()
    #expect(!cecWorkerMayRelease(life))
    life.phase = .stopped
    #expect(cecWorkerMayRelease(life))
    life.totalOutstanding = 1
    #expect(!cecWorkerMayRelease(life))
    var armed = false
    let first = cecNotificationMarkRearmed(&armed)
    let duplicate = cecNotificationMarkRearmed(&armed)
    #expect(first && !duplicate)
    let delivered = cecNotificationMarkDelivered(&armed)
    let again = cecNotificationMarkDelivered(&armed)
    #expect(delivered && !again)
    #expect(cecSessionTerminalAccountingValid(claimed: 10, echoed: 8, corrupted: 1, lost: 1))
    #expect(!cecSessionTerminalAccountingValid(claimed: 10, echoed: 8, corrupted: 0, lost: 1))
  }
}
