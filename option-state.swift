// Prints "1" if the Option (Alt) modifier is currently held, "0" otherwise.
// Uses CGEventSource for system-wide modifier state without focus.
// Compiled once at daemon startup; per-call cost is ~30ms warm.
import CoreGraphics

let flags = CGEventSource.flagsState(.combinedSessionState)
print(flags.contains(.maskAlternate) ? "1" : "0")
