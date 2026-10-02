import CECClientCore

func take(_ value: consuming CECSocketOwner) {}
func valid() {
  var owners = UniqueArray<CECSocketOwner>()
  owners.append(CECSocketOwner())
  owners[0].reset()
  let owner = CECHandleOwner()
  let moved = consume owner
  _ = moved.rawValue
  take(CECSocketOwner())
}
