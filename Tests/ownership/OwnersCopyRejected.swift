import CECClientCore

func take(_ value: consuming CECSocketOwner) {}
func invalid() {
  let owner = CECSocketOwner()
  take(consume owner)
  take(consume owner)
}
