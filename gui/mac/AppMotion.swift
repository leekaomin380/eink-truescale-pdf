import AppKit
import SwiftUI

/// Mirrors Day Mark's Theme.Motion: ink changes, the paper/frame stays still.
/// Native controls retain their built-in interactions; no extra press/hover springs.
enum AppMotion {
    static var isReduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    static var micro: Animation {
        isReduced ? .easeInOut(duration: 0.15) : .timingCurve(0.2, 0, 0, 1, duration: 0.12)
    }
    static var expand: Animation {
        isReduced ? .easeInOut(duration: 0.15) : .spring(response: 0.30, dampingFraction: 1)
    }
    static var navigate: Animation {
        isReduced ? .easeInOut(duration: 0.15) : .spring(response: 0.36, dampingFraction: 1)
    }
    static var exit: Animation {
        isReduced ? .easeInOut(duration: 0.15) : .timingCurve(0.4, 0, 1, 1, duration: 0.16)
    }
    static var hintTransition: AnyTransition {
        isReduced ? .opacity : .asymmetric(
            insertion: .opacity.combined(with: .offset(y: 4)), removal: .opacity)
    }
}
