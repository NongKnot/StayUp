import Foundation

/// Classical peak-detection step counter for the carried-laptop case.
///
/// Algorithm (no ML):
///   1. magnitude  = √(x² + y² + z²)
///   2. gravityEMA = slow EMA on magnitude (~1 s window) — tracks tilt
///   3. signal     = magnitude − gravityEMA              — vertical jerk
///   4. signalEMA  = short EMA on signal (~0.3 s)        — smoothing
///   5. step       = signalEMA crosses above stepThreshold AND
///                   ≥ minStepGap has elapsed since the last peak
///
/// Threshold defaults are tuned for a MacBook held in one hand. Backpack
/// carry would need a lower threshold; out of scope for the current animation.
struct StepCounter {

    // MARK: - Tunables

    var stepThreshold: Double      = 0.08
    var minStepGap:    TimeInterval = 0.30
    var gravityAlpha:  Double      = 0.05    // ~1 s window at 14 Hz
    var signalAlpha:   Double      = 0.40    // ~0.3 s window

    // MARK: - State

    private var gravityEMA: Double = 1.0
    private var signalEMA:  Double = 0.0
    private var lastPeakAt: Date?
    private var aboveThreshold = false

    private(set) var sessionSteps: Int = 0

    // MARK: - API

    @discardableResult
    mutating func processSample(x: Double, y: Double, z: Double, now: Date) -> Bool {
        let mag    = (x*x + y*y + z*z).squareRoot()
        gravityEMA += (mag - gravityEMA) * gravityAlpha
        let signal = mag - gravityEMA
        signalEMA  += (signal - signalEMA) * signalAlpha

        if signalEMA > stepThreshold {
            if !aboveThreshold {
                aboveThreshold = true
                if lastPeakAt == nil || now.timeIntervalSince(lastPeakAt!) >= minStepGap {
                    lastPeakAt = now
                    sessionSteps += 1
                    return true
                }
            }
        } else {
            aboveThreshold = false
        }
        return false
    }

    mutating func reset() {
        sessionSteps   = 0
        gravityEMA     = 1.0
        signalEMA      = 0.0
        lastPeakAt     = nil
        aboveThreshold = false
    }
}
