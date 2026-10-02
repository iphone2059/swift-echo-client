import CECClientCore
func consumeConfiguration(_ configuration: consuming CECWorkerConfiguration) {}
func duplicated(_ configuration: consuming CECWorkerConfiguration) {
  unsafe consumeConfiguration(copy configuration)
  unsafe consumeConfiguration(configuration)
}
