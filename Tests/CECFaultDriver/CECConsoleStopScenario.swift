import CECClientCore
import WinSDK

/// Runs a hidden console child so generating Ctrl+Break cannot affect the caller's console.
func cecExerciseConsoleStop(clientPath: String, port: UInt16, readyName: String)
  -> CECExitCode
{
  var startup = STARTUPINFOW()
  startup.cb = DWORD(MemoryLayout<STARTUPINFOW>.size)
  startup.dwFlags = DWORD(STARTF_USESHOWWINDOW)
  startup.wShowWindow = 0
  var info = PROCESS_INFORMATION()
  var command =
    Array("\"\(clientPath)\" 127.0.0.1 /p tcp /r \(port) /n 0 /z 4096 /t 30 /q".utf16) + [0]
  let created = command.withUnsafeMutableBufferPointer {
    CreateProcessW(
      nil, $0.baseAddress, nil, nil, false, DWORD(CREATE_NEW_CONSOLE | CREATE_NEW_PROCESS_GROUP),
      nil, nil, &startup, &info)
  }
  guard created, let process = info.hProcess else {
    cecFailFast(stage: "console child CreateProcessW", error: Int32(bitPattern: GetLastError()))
  }
  let processOwner = CECHandleOwner(process)
  let threadOwner = CECHandleOwner(info.hThread)
  func failChild(_ stage: String, _ error: Int32) -> Never {
    TerminateProcess(process, 4)
    WaitForSingleObject(process, 5000)
    cecFailFast(stage: stage, error: error)
  }
  defer {
    if WaitForSingleObject(process, 0) != WAIT_OBJECT_0 {
      TerminateProcess(process, 4)
      WaitForSingleObject(process, 5000)
    }
    _ = processOwner.rawValue
    _ = threadOwner.rawValue
  }
  let eventName = Array(readyName.utf16) + [0]
  let event = eventName.withUnsafeBufferPointer {
    OpenEventW(DWORD(SYNCHRONIZE), false, $0.baseAddress)
  }
  let eventOwner = CECHandleOwner(event)
  guard event != nil, WaitForSingleObject(event, 5000) == WAIT_OBJECT_0 else {
    failChild("console child peer readiness", 1460)
  }
  _ = eventOwner.rawValue
  FreeConsole()
  guard AttachConsole(info.dwProcessId), SetConsoleCtrlHandler({ _ in true }, true),
    GenerateConsoleCtrlEvent(DWORD(CTRL_BREAK_EVENT), info.dwProcessId)
  else { failChild("console child Ctrl+Break", Int32(bitPattern: GetLastError())) }
  guard WaitForSingleObject(process, 5000) == WAIT_OBJECT_0 else {
    failChild("console child drain timeout", 1460)
  }
  var code: DWORD = 4
  guard GetExitCodeProcess(process, &code), code == 0 else {
    failChild("console child exit", Int32(bitPattern: code))
  }
  FreeConsole()
  return .success
}
