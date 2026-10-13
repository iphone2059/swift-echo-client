import CECClientCore

func duplicateCore(_ core: consuming CECWorkerCore) {
  let duplicate = copy core
  _ = duplicate.metrics.claimed
  _ = core.metrics.claimed
}
