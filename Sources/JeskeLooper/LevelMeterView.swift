import Foundation
import LooperCore
import SwiftUI

/// Polls the input peak at 30 Hz. Only the meter observes this, so the rest of the window
/// does not redraw with it.
@MainActor
final class MeterModel: ObservableObject {
    @Published private(set) var left: Double = 0
    @Published private(set) var right: Double = 0
    @Published private(set) var channels = 0
    @Published private(set) var peakDB: Double = -.infinity
    @Published private(set) var clipping = false

    private var timer: Timer?
    private var clipUntil = Date.distantPast
    private var holdDB: Double = -.infinity
    private var holdUntil = Date.distantPast

    func start(_ level: InputLevel) {
        stop()
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick(level) }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick(_ level: InputLevel) {
        let s = level.consume()
        let now = Date()
        left = max(Self.normalized(s.left), left - 0.035)
        right = max(Self.normalized(s.right), right - 0.035)
        if s.channels != channels { channels = s.channels }
        let peak = Double(max(s.left, s.right))
        if peak >= 0.999 { clipUntil = now.addingTimeInterval(1.5) }
        let clip = now < clipUntil
        if clip != clipping { clipping = clip }
        let db = peak > 0 ? 20 * log10(peak) : -.infinity
        if db >= holdDB || now > holdUntil {
            holdDB = db
            holdUntil = now.addingTimeInterval(0.8)
        }
        if holdDB != peakDB { peakDB = holdDB }
    }

    /// -60 dBFS … 0 dBFS → 0 … 1.
    static func normalized(_ peak: Float) -> Double {
        guard peak > 0 else { return 0 }
        return min(max((20 * log10(Double(peak)) + 60) / 60, 0), 1)
    }
}

struct LevelMeterView: View {
    let level: InputLevel
    let active: Bool
    @StateObject private var meter = MeterModel()

    var body: some View {
        HStack(spacing: 8) {
            Text("Nível").font(.caption).foregroundStyle(.secondary).frame(width: 36, alignment: .leading)
            VStack(spacing: 3) {
                MeterBar(value: meter.left)
                if meter.channels > 1 { MeterBar(value: meter.right) }
            }
            .frame(height: meter.channels > 1 ? 15 : 8)
            Text(dbText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(meter.clipping ? Color.red : Color.secondary)
                .frame(width: 54, alignment: .trailing)
        }
        .opacity(active ? 1 : 0.45)
        .onAppear { meter.start(level) }
        .onDisappear { meter.stop() }
        .help("Nível do áudio que chega pela entrada")
    }

    private var dbText: String {
        if meter.clipping { return "CLIP" }
        guard meter.peakDB.isFinite, meter.peakDB > -60 else { return "— dB" }
        return "\(Int(meter.peakDB.rounded())) dB"
    }
}

struct MeterBar: View {
    let value: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(LinearGradient(stops: [
                        .init(color: Theme.play, location: 0),
                        .init(color: Theme.play, location: 0.62),
                        .init(color: .yellow, location: 0.82),
                        .init(color: Theme.record, location: 1),
                    ], startPoint: .leading, endPoint: .trailing))
                    .mask(alignment: .leading) {
                        Rectangle().frame(width: geo.size.width * value)
                    }
            }
        }
    }
}
