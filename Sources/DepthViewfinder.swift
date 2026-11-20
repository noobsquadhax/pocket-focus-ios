import ARKit
import AVFoundation
import CoreImage
import Vision

struct ViewfinderFrame {
    let image: CGImage
    let subjects: [FocusSubject]
    let centerDepth: Double?
    let receivedAt: TimeInterval
}

final class DepthViewfinder: NSObject, ARSessionDelegate {
    var onFrame: ((ViewfinderFrame) -> Void)?
    var onState: ((String) -> Void)?

    private let session = ARSession()
    private let queue = DispatchQueue(label: "pocketfocus.viewfinder", qos: .userInitiated)
    private let context = CIContext()
    private let faceRequest = VNDetectFaceRectanglesRequest()
    private let bodyRequest = VNDetectHumanBodyPoseRequest()
    private var lastAnalysis: TimeInterval = 0
    private var running = false
    private var generation = 0

    override init() {
        super.init()
        session.delegate = self
        session.delegateQueue = queue
    }

    func start() {
        guard !running else { return }
        guard ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) else {
            onState?("Rear LiDAR is required. Manual focus is available.")
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            let configuration = ARWorldTrackingConfiguration()
            configuration.frameSemantics = [.sceneDepth]
            running = true
            generation += 1
            let currentGeneration = generation
            queue.async {
                self.captureGeneration = currentGeneration
                self.lastAnalysis = 0
            }
            onState?("Starting LiDAR…")
            session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        case .notDetermined:
            let requestedGeneration = generation
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self, self.generation == requestedGeneration else { return }
                    if granted {
                        self.start()
                    } else {
                        self.onState?("Allow camera access in Settings.")
                    }
                }
            }
        default:
            onState?("Allow camera access in Settings.")
        }
    }

    func stop() {
        generation += 1
        running = false
        session.pause()
    }

    // Accessed on the ARSession delegate queue.
    private var captureGeneration = 0

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastAnalysis >= 1.0 / 12 else { return }
        lastAnalysis = now
        let portrait = CIImage(cvPixelBuffer: frame.capturedImage).oriented(.right)
        let preview = portrait.transformed(by: CGAffineTransform(scaleX: 0.5, y: 0.5))
        guard let image = context.createCGImage(preview, from: preview.extent.integral) else { return }
        let handler = VNImageRequestHandler(cvPixelBuffer: frame.capturedImage, orientation: .right)
        let subjects: [FocusSubject]
        do {
            try handler.perform([faceRequest, bodyRequest])
            subjects = identifySubjects(using: frame.sceneDepth)
        } catch {
            subjects = []
        }
        let center = readDepth(frame.sceneDepth, at: CGPoint(x: 0.5, y: 0.5), radius: 0.016)
        let result = ViewfinderFrame(image: image, subjects: subjects, centerDepth: center, receivedAt: now)
        let version = captureGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, self.running, self.generation == version else { return }
            self.onFrame?(result)
        }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        report("LiDAR stopped. Reopen the app to retry.")
    }

    func sessionWasInterrupted(_ session: ARSession) {
        report("Camera interrupted.")
    }

    private func report(_ message: String) {
        let version = captureGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, self.running, self.generation == version else { return }
            self.onState?(message)
        }
    }

    private func identifySubjects(using depth: ARDepthData?) -> [FocusSubject] {
        let faces = (faceRequest.results ?? []).filter { $0.confidence >= 0.5 }
            .map { CGRect(x: $0.boundingBox.minX, y: 1 - $0.boundingBox.maxY,
                          width: $0.boundingBox.width, height: $0.boundingBox.height) }
        var subjects: [FocusSubject] = []
        var usedFaces = Set<Int>()
        for pose in bodyRequest.results ?? [] {
            guard let joints = try? pose.recognizedPoints(.all),
                  let left = joints[.leftShoulder], let right = joints[.rightShoulder],
                  left.confidence >= 0.35, right.confidence >= 0.35 else { continue }
            let points = joints.values.filter { $0.confidence >= 0.35 }.map {
                CGPoint(x: $0.location.x, y: 1 - $0.location.y)
            }
            guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
                  let minY = points.map(\.y).min(), let maxY = points.map(\.y).max() else { continue }
            let shoulderX = (left.location.x + right.location.x) / 2
            let shoulderY = 1 - (left.location.y + right.location.y) / 2
            let shoulderWidth = abs(right.location.x - left.location.x)
            let faceCandidates = faces.indices.filter { index in
                let face = faces[index]
                return !usedFaces.contains(index)
                    && abs(face.midX - shoulderX) < max(0.035, shoulderWidth * 0.65)
                    && face.midY <= shoulderY + 0.025
                    && shoulderY - face.midY < max(0.08, shoulderWidth * 0.8)
            }
            let faceIndex = faceCandidates.min {
                abs(faces[$0].midX - shoulderX) < abs(faces[$1].midX - shoulderX)
            }
            let face = faceIndex.map { faces[$0] }
            if let faceIndex { usedFaces.insert(faceIndex) }
            let body = CGRect(x: minX - 0.024, y: minY - 0.035,
                              width: maxX - minX + 0.048, height: maxY - minY + 0.07)
            let chest = CGPoint(x: shoulderX, y: shoulderY + max(0.014, shoulderWidth * 0.23))
            let measured: Double?
            if let face {
                measured = faceDepth(depth, face: face)
            } else {
                measured = readDepth(depth, at: chest, radius: max(0.01, min(0.022, shoulderWidth * 0.14)))
            }
            subjects.append(FocusSubject(id: subjects.count, bounds: face.map { body.union($0) } ?? body,
                                         face: face, depth: measured))
        }
        for (index, face) in faces.enumerated() where !usedFaces.contains(index) {
            subjects.append(FocusSubject(id: subjects.count, bounds: face.insetBy(dx: -0.012, dy: -0.009),
                                         face: face, depth: faceDepth(depth, face: face)))
        }
        return subjects
    }

    private func faceDepth(_ depth: ARDepthData?, face: CGRect) -> Double? {
        let point = CGPoint(x: face.midX, y: face.minY + face.height * 0.46)
        return readDepth(depth, at: point, radius: min(0.018, face.width * 0.15, face.height * 0.15))
    }

    private func readDepth(_ depth: ARDepthData?, at point: CGPoint, radius: CGFloat) -> Double? {
        guard let depth, let confidence = depth.confidenceMap else { return nil }
        let map = depth.depthMap
        guard CVPixelBufferGetPixelFormatType(map) == kCVPixelFormatType_DepthFloat32,
              CVPixelBufferGetPixelFormatType(confidence) == kCVPixelFormatType_OneComponent8,
              CVPixelBufferLockBaseAddress(map, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
        guard CVPixelBufferLockBaseAddress(confidence, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(confidence, .readOnly) }
        guard let address = CVPixelBufferGetBaseAddress(map),
              let quality = CVPixelBufferGetBaseAddress(confidence) else { return nil }
        let width = CVPixelBufferGetWidth(map)
        let height = CVPixelBufferGetHeight(map)
        guard CVPixelBufferGetWidth(confidence) == width, CVPixelBufferGetHeight(confidence) == height else { return nil }
        let stride = CVPixelBufferGetBytesPerRow(map)
        let qualityStride = CVPixelBufferGetBytesPerRow(confidence)
        var readings: [Double] = []
        var sampled = Set<Int>()
        for i in -2...2 {
            for j in -2...2 {
                // Undo the clockwise portrait rotation before addressing the sensor map.
                let u = point.y + CGFloat(j) * radius / 2
                let v = 1 - (point.x + CGFloat(i) * radius / 2)
                guard (0..<1).contains(u), (0..<1).contains(v) else { continue }
                let x = Int(u * CGFloat(width))
                let y = Int(v * CGFloat(height))
                guard sampled.insert(y * width + x).inserted,
                      quality.load(fromByteOffset: y * qualityStride + x, as: UInt8.self) >= UInt8(ARConfidenceLevel.medium.rawValue)
                else { continue }
                let meters = Double(address.load(fromByteOffset: y * stride + x * MemoryLayout<Float>.stride, as: Float.self))
                if (0.30...5.0).contains(meters) { readings.append(meters) }
            }
        }
        guard readings.count >= 4 else { return nil }
        readings.sort()
        let spread = readings[readings.count * 3 / 4] - readings[readings.count / 4]
        guard spread <= 0.18 else { return nil }
        return readings[readings.count / 2]
    }
}
