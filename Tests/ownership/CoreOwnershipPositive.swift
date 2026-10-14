import CECClientCore

func coreOwnershipPositive() throws -> UInt64 {
  var options = CECOptions()
  options.transport = .tcp
  let original = try CECWorkerCore(
    options: options, sessionCount: 1, payloadBytes: 1, frequency: 1000)
  var core = consume original
  _ = core.start(now: 0)
  var values = try CECFixedArray(count: 1, repeating: UInt64(42))
  values[0] += core.metrics.claimed
  return values[0]
}
