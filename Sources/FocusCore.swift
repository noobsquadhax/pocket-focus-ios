import Foundation

enum LensPacket {
    static func focus(_ value: Double, relative: Bool = false) -> Data? {
        guard value.isFinite else { return nil }
        let clamped = min(max(value, relative ? -1 : 0), 1)
        let fixed = UInt16(bitPattern: Int16((clamped * 2048).rounded()))
        return Data([
            255, 6, 0, 0, 0, 0, 128, relative ? 1 : 0,
            UInt8(truncatingIfNeeded: fixed), UInt8(fixed >> 8), 0, 0
        ])
    }
}

struct FocusMark: Codable, Identifiable {
    var id = UUID()
    let meters: Double
    let command: Double
}

struct LensProfile: Codable {
    var marks: [FocusMark] = []

    var isUsable: Bool {
        guard marks.count >= 3, let first = marks.first, let last = marks.last,
              first.meters > 0, last.command - first.command >= 0.025,
              marks.allSatisfy({ $0.meters.isFinite && (0...1).contains($0.command) })
        else { return false }
        return zip(marks, marks.dropFirst()).allSatisfy { pair in
            let (near, far) = pair
            return far.meters - near.meters >= 0.05 && far.command > near.command
        }
    }

    mutating func add(meters: Double, command: Double) {
        guard meters.isFinite, meters > 0, (0...1).contains(command) else { return }
        marks.removeAll { abs($0.meters - meters) < 0.06 }
        marks.append(FocusMark(meters: meters, command: command))
        marks.sort { $0.meters < $1.meters }
    }

    func command(at meters: Double) -> Double? {
        guard isUsable, let first = marks.first, let last = marks.last,
              (first.meters...last.meters).contains(meters) else { return nil }
        for (near, far) in zip(marks, marks.dropFirst()) where meters <= far.meters {
            let fraction = (1 / near.meters - 1 / meters) / (1 / near.meters - 1 / far.meters)
            return near.command + fraction * (far.command - near.command)
        }
        return last.command
    }
}

struct FocusFilter {
    private var previous: Double?

    mutating func reset() { previous = nil }

    mutating func update(_ requested: Double, startingAt current: Double) -> Double {
        let from = previous ?? current
        let movement = min(max(0.62 * (requested - from), -0.12), 0.12)
        let result = from + movement
        previous = result
        return result
    }
}

struct FocusSubject: Identifiable {
    let id: Int
    let bounds: CGRect
    let face: CGRect?
    let depth: Double?

    var trackingPoint: CGPoint { CGPoint(x: bounds.midX, y: bounds.midY) }
    var facePoint: CGPoint? { face.map { CGPoint(x: $0.midX, y: $0.midY) } }

    static func match(_ tracked: FocusSubject, in subjects: [FocusSubject]) -> FocusSubject? {
        let matches = subjects.compactMap { subject -> (FocusSubject, CGFloat)? in
            let center = separation(tracked.trackingPoint, subject.trackingPoint)
            let movement = min(center, separation(tracked.facePoint ?? tracked.trackingPoint,
                                                  subject.facePoint ?? subject.trackingPoint))
            let overlap = tracked.bounds.intersection(subject.bounds)
            guard movement <= 0.14,
                  (!overlap.isNull && overlap.width > 0 && overlap.height > 0) || movement <= 0.075
            else { return nil }
            let delta = nearbyDepthDifference(tracked.depth, subject.depth)
            guard delta <= 0.65 else { return nil }
            return (subject, movement + CGFloat(delta) * 0.10)
        }.sorted { $0.1 < $1.1 }
        guard let best = matches.first else { return nil }
        if let other = matches.dropFirst().first, other.1 - best.1 < 0.04 { return nil }
        return best.0
    }

    static func separation(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }

    private static func nearbyDepthDifference(_ first: Double?, _ second: Double?) -> Double {
        guard let first, let second else { return 0 }
        return abs(first - second)
    }
}
