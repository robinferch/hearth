// Intentionally imports only HearthData: on macOS, SwiftUI pulls in QuickDraw's C `RGBColor`, which makes
// the name ambiguous. HearthUI refers to the HearthData type through this alias.
import HearthData

/// HearthData's `RGBColor` (dominant cover color), unambiguous on every platform.
public typealias HearthRGBColor = RGBColor
