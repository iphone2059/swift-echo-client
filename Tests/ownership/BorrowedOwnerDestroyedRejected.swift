import CECClientCore

func take(_ value: consuming CECHandleOwner) {}
func invalid(_ owner: borrowing CECHandleOwner) { take(consume owner) }
