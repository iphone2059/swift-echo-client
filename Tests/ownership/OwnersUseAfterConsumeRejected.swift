import CECClientCore

func take(_ value: consuming CECHandleOwner) {}
func invalid() {
  let owner = CECHandleOwner()
  take(consume owner)
  _ = owner.rawValue
}
