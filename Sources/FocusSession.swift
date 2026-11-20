import Combine
import Foundation

final class FocusSession: ObservableObject {
    let link = BlackmagicLink()
    let viewfinder = DepthViewfinder()

    @Published private(set) var frame: ViewfinderFrame?
    @Published private(set) var marker: CGRect?
    @Published private(set) var meters: Double?
    @Published private(set) var trackingState = "Tap a person to lock"
    @Published private(set) var previewState = "Starting LiDAR…"
    @Published private(set) var armed = false
    @Published private(set) var verifiedPull = false
    @Published private(set) var lastCommand: Double?
    @Published private(set) var profile: LensProfile
    @Published var setting = 0.5
    @Published var manualMessage = "Set a value, then send it to the camera."

    private static let profileKey = "pocketfocus.lensProfile.v1"
    private var tracked: FocusSubject?
    private var lastSeen: TimeInterval = 0
    private var filter = FocusFilter()
    private var active = false
    private var acknowledgedManual: [Double] = []
    private var pendingManual = false
    @Published private(set) var lastManualCommand: Double?
    private var watchdog: AnyCancellable?

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.profileKey),
           let saved = try? JSONDecoder().decode(LensProfile.self, from: data) {
            profile = saved
        } else {
            profile = LensProfile()
        }
        viewfinder.onFrame = { [weak self] frame in self?.consume(frame) }
        viewfinder.onState = { [weak self] message in
            guard let self else { return }
            self.frame = nil
            self.previewState = message
            self.clearTarget()
        }
        link.onReset = { [weak self] in
            guard let self else { return }
            self.disarm()
            self.verifiedPull = false
            self.lastCommand = nil
            self.lastManualCommand = nil
            self.pendingManual = false
            self.acknowledgedManual = []
            self.manualMessage = "Reconnect before sending focus commands."
        }
        link.onWrite = { [weak self] value in
            guard let self else { return }
            self.lastCommand = value
            self.lastManualCommand = self.pendingManual ? value : nil
            if self.pendingManual {
                self.pendingManual = false
                if let value {
                    self.acknowledgedManual.append(value)
                    self.acknowledgedManual = Array(self.acknowledgedManual.suffix(3))
                }
                self.manualMessage = "Bluetooth write acknowledged. Check focus on the Pocket 6K."
            }
        }
    }

    func setActive(_ enabled: Bool) {
        guard active != enabled else { return }
        active = enabled
        if enabled {
            viewfinder.start()
            watchdog = Timer.publish(every: 0.2, on: .main, in: .common).autoconnect().sink { [weak self] _ in
                guard let self, let frame = self.frame, !self.isFresh(frame) else { return }
                self.frame = nil
                self.clearTarget()
                self.previewState = "Waiting for a fresh camera frame…"
            }
        } else {
            watchdog = nil
            clearTarget()
            frame = nil
            viewfinder.stop()
        }
    }

    func select(at point: CGPoint) {
        guard let frame, isFresh(frame) else { return }
        let candidates = frame.subjects.filter { $0.bounds.contains(point) }
        guard let candidate = candidates.first(where: { $0.face?.contains(point) == true })
            ?? candidates.min(by: { FocusSubject.separation($0.trackingPoint, point) < FocusSubject.separation($1.trackingPoint, point) })
        else { return }
        select(candidate)
    }

    func select(_ subject: FocusSubject) {
        guard let frame, isFresh(frame) else { return }
        disarm()
        tracked = subject
        lastSeen = frame.receivedAt
        marker = subject.bounds
        meters = subject.depth
        trackingState = subject.face == nil ? "Body lock" : "Face lock"
    }

    func clearTarget() {
        disarm()
        tracked = nil
        marker = nil
        meters = nil
        trackingState = "Tap a person to lock"
    }

    var canArm: Bool {
        guard active, link.ready, !link.busy, verifiedPull, let lastCommand,
              let frame, isFresh(frame), let meters, tracked != nil,
              let low = profile.marks.first?.command, let high = profile.marks.last?.command,
              profile.command(at: meters) != nil else { return false }
        return (low...high).contains(lastCommand)
    }

    func arm() {
        guard canArm else { return }
        filter.reset()
        armed = true
    }

    func disarm() {
        armed = false
        filter.reset()
    }

    func manualSend(_ value: Double) {
        guard active else { return }
        disarm()
        if link.send(value) {
            pendingManual = true
            manualMessage = "Sending focus command…"
        }
    }

    func nudge(_ increment: Double) {
        guard active else { return }
        disarm()
        if link.send(increment, relative: true) {
            pendingManual = true
            verifiedPull = false
            lastCommand = nil
            acknowledgedManual = []
            manualMessage = "Sending relative movement…"
        }
    }

    var canVerifyPull: Bool {
        guard acknowledgedManual.count == 3 else { return false }
        let a = acknowledgedManual[0], b = acknowledgedManual[1], returnToA = acknowledgedManual[2]
        return !link.busy && abs(a - b) >= 0.02 && abs(a - returnToA) < 0.002
    }

    func confirmPull() {
        guard canVerifyPull else { return }
        verifiedPull = true
        manualMessage = "A–B–A repeatability confirmed by operator."
    }

    var calibrationDepth: Double? {
        guard let frame, isFresh(frame) else { return nil }
        return frame.centerDepth
    }

    func saveMark() {
        guard !armed, !link.busy, let meters = calibrationDepth, let lastManualCommand else { return }
        profile.add(meters: meters, command: lastManualCommand)
        persist()
    }

    func removeMark(_ id: UUID) {
        disarm()
        profile.marks.removeAll { $0.id == id }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(profile) {
            UserDefaults.standard.set(data, forKey: Self.profileKey)
        }
    }

    private func consume(_ next: ViewfinderFrame) {
        guard active, isFresh(next) else { return }
        frame = next
        guard let tracked else { return }
        if next.receivedAt - lastSeen >= 0.45 {
            clearTarget()
            trackingState = "Target lost · tap to relock"
            return
        }
        guard let subject = FocusSubject.match(tracked, in: next.subjects) else {
            meters = nil
            disarm()
            trackingState = "Holding · target uncertain"
            return
        }
        self.tracked = subject
        lastSeen = next.receivedAt
        marker = subject.bounds
        meters = subject.depth
        guard let measured = subject.depth else {
            disarm()
            trackingState = "Holding · no reliable depth"
            return
        }
        trackingState = subject.face == nil ? "Body lock" : "Face lock"
        guard armed else { return }
        guard let goal = profile.command(at: measured), let applied = lastCommand else {
            disarm()
            trackingState = "Holding · outside calibrated range"
            return
        }
        guard link.ready, !link.busy else { return }
        let value = filter.update(goal, startingAt: applied)
        if abs(value - applied) >= 0.004 { link.send(value) }
    }

    private func isFresh(_ frame: ViewfinderFrame) -> Bool {
        ProcessInfo.processInfo.systemUptime - frame.receivedAt < 0.35
    }

}
