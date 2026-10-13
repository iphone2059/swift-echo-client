import CECClientCore

func duplicateStorage(_ storage: consuming CECFixedArray<UInt64>) {
  let duplicate = copy storage
  _ = duplicate[0]
  _ = storage[0]
}
