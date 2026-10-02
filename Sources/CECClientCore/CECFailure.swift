import Foundation
import WinSDK

package func cecReport(stage: String, error: Int32) {
  FileHandle.standardError.write(Data("\(stage) failed: native_error=\(error)\n".utf8))
}
package func cecFailFast(stage: String, error: Int32) -> Never {
  cecReport(stage: stage, error: error)
  while true { unsafe TerminateProcess(GetCurrentProcess(), 4) }
}
package func cecRequireRIONotifySuccess(_ status: Int32, stage: String) {
  if status != 0 { cecFailFast(stage: stage, error: status) }
}
package func cecRequireValidDequeueCount(_ count: UInt32, stage: String) -> UInt32 {
  if count == UInt32.max { cecFailFast(stage: stage, error: 13) }
  return count
}
package func cecRequireNotificationPacket(
  key: UInt, overlapped: UnsafePointer<OVERLAPPED>?, expectedKey: UInt,
  expectedOverlapped: UnsafePointer<OVERLAPPED>?, stage: String
) {
  if unsafe !cecNotificationPacketMatches(
    key: key, overlapped: overlapped, expectedKey: expectedKey,
    expectedOverlapped: expectedOverlapped)
  {
    cecFailFast(stage: stage, error: 13)
  }
}
package func cecRequireOutstanding(_ count: UInt32, stage: String) {
  if count == 0 { cecFailFast(stage: stage, error: 13) }
}
package func cecRequireControlPostSuccess(_ succeeded: Bool, error: Int32, stage: String) {
  if !succeeded { cecFailFast(stage: stage, error: error) }
}
