// Prints the system-wide modifier state for the voice daemon (no focus needed):
//   "2" = Control+Option+Command held: stop all speech now and clear queues
//   "1" = only Option held: pause before the next sentence (push-to-mute)
//   "0" = neither
import CoreGraphics

let flags = CGEventSource.flagsState(.combinedSessionState)
if flags.contains(.maskControl) && flags.contains(.maskAlternate) && flags.contains(.maskCommand) {
    print("2")
} else {
    print(flags.contains(.maskAlternate) ? "1" : "0")
}
