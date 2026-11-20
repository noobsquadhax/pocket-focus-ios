import SwiftUI
import UIKit

@main
struct PocketFocusApp: App {
    @StateObject private var session = FocusSession()

    var body: some Scene {
        WindowGroup {
            FocusScreen(session: session, link: session.link)
                .preferredColorScheme(.dark)
        }
    }
}

struct FocusScreen: View {
    @ObservedObject var session: FocusSession
    @ObservedObject var link: BlackmagicLink
    @Environment(\.scenePhase) private var scenePhase
    @State private var showCamera = false
    @State private var showLens = false

    private let accent = Color(red: 0.98, green: 0.78, blue: 0.42)
    private let background = Color(red: 0.066, green: 0.073, blue: 0.076)
    private let panel = Color(red: 0.115, green: 0.127, blue: 0.13)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                viewfinder
                readout
                controls
            }
            .frame(maxWidth: 480)
            .padding(16)
            .frame(maxWidth: .infinity)
        }
        .background(background.ignoresSafeArea())
        .tint(accent)
        .onAppear { session.setActive(scenePhase == .active) }
        .onChange(of: scenePhase) { phase in session.setActive(phase == .active) }
        .onChange(of: session.armed) { armed in UIApplication.shared.isIdleTimerDisabled = armed }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        .sheet(isPresented: $showCamera) { cameraSheet }
        .sheet(isPresented: $showLens) { lensSheet }
    }

    private var header: some View {
        HStack(alignment: .center) {
            Text("Pocket Focus")
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Button {
                session.disarm()
                showCamera = true
            } label: {
                Label(link.ready ? "Connected" : "Camera", systemImage: link.ready ? "link" : "link.badge.plus")
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 12)
                    .frame(minHeight: 44)
                    .background(panel, in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Open Bluetooth camera controls")
        }
    }

    private var viewfinder: some View {
        GeometryReader { geometry in
            ZStack {
                RoundedRectangle(cornerRadius: 16).fill(.black)
                if let frame = session.frame {
                    let available = geometry.size
                    let aspect = CGFloat(frame.image.width) / CGFloat(frame.image.height)
                    let width = min(available.width, available.height * aspect)
                    let height = width / aspect
                    Image(decorative: frame.image, scale: 1)
                        .resizable()
                        .frame(width: width, height: height)
                        .overlay {
                            subjectMarkers(frame.subjects, width: width, height: height)
                        }
                        .contentShape(Rectangle())
                        .gesture(SpatialTapGesture().onEnded {
                            session.select(at: CGPoint(x: $0.location.x / width, y: $0.location.y / height))
                        })
                        .clipped()
                        .accessibilityHidden(true)
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "viewfinder").font(.largeTitle).foregroundStyle(accent)
                        Text(session.previewState).font(.subheadline).multilineTextAlignment(.center)
                    }
                    .padding(20)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.12)) }
        }
        .frame(height: 388)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("iPhone viewfinder")
    }

    private func subjectMarkers(_ subjects: [FocusSubject], width: CGFloat, height: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(subjects) { subject in
                outline(subject.bounds, width: width, height: height, selected: false)
            }
            if let marker = session.marker {
                outline(marker, width: width, height: height, selected: true)
            }
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    private func outline(_ bounds: CGRect, width: CGFloat, height: CGFloat, selected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 7)
            .strokeBorder(selected ? accent : .white.opacity(0.65), lineWidth: selected ? 2.5 : 1)
            .frame(width: bounds.width * width, height: bounds.height * height)
            .offset(x: bounds.minX * width, y: bounds.minY * height)
            .shadow(color: .black.opacity(0.6), radius: 2)
    }

    private var readout: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(session.armed ? "Autofocus on" : session.trackingState)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(session.armed ? accent : .primary)
                Text(session.armed ? session.trackingState : "Subject distance")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            Text(session.meters.map { $0.formatted(.number.precision(.fractionLength(2))) + " m" } ?? "— m")
                .font(.title2.monospacedDigit())
                .accessibilityLabel(session.meters.map { $0.formatted(.number.precision(.fractionLength(2))) + " meters" } ?? "Distance unavailable")
        }
        .padding(14)
        .background(panel, in: RoundedRectangle(cornerRadius: 12))
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Button(session.armed ? "Hold focus" : "Start autofocus") {
                    if session.armed { session.disarm() } else { session.arm() }
                }
                .buttonStyle(.borderedProminent)
                .tint(accent)
                .foregroundStyle(.black)
                .disabled(!session.armed && !session.canArm)
                Button("Lens setup") {
                    session.disarm()
                    showLens = true
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.large)
            if let frame = session.frame, !frame.subjects.isEmpty {
                Menu("Select subject") {
                    ForEach(frame.subjects) { subject in
                        Button("Person \(subject.id + 1) · \(subject.face == nil ? "body" : "face")") {
                            session.select(subject)
                        }
                    }
                    Button("Clear lock", action: session.clearTarget)
                }
            }
            if !session.verifiedPull {
                Text("Verify a repeatable pull in Lens setup to enable autofocus.")
                    .font(.footnote).foregroundStyle(.secondary)
            } else if !session.profile.isUsable {
                Text("Save at least three increasing lens marks in Lens setup.")
                    .font(.footnote).foregroundStyle(.secondary)
            } else if !session.armed && session.meters != nil && !session.canArm {
                Text("Autofocus needs a live camera link and a subject and lens position within the calibrated range.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var cameraSheet: some View {
        NavigationStack {
            List {
                Text(link.status).accessibilityAddTraits(.updatesFrequently)
                if link.ready || link.connecting {
                    Button(link.connecting ? "Cancel connection" : "Disconnect") { link.disconnect() }
                } else {
                    Button(link.scanning ? "Searching…" : "Find Blackmagic camera", action: link.scan)
                        .disabled(link.scanning)
                    ForEach(link.cameras) { camera in
                        Button(camera.name) { link.connect(camera.id) }
                    }
                    Text("Turn on Bluetooth in the camera’s Setup menu. If iOS asks for a pairing code, use the one displayed on the Pocket 6K.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Camera")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showCamera = false } } }
        }
    }

    private var lensSheet: some View {
        NavigationStack {
            List {
                Section("Manual focus") {
                    LabeledContent("Focus command", value: session.setting.formatted(.number.precision(.fractionLength(3))))
                    Slider(value: $session.setting, in: 0...1)
                        .accessibilityLabel("Focus command")
                    Button("Send focus command") { session.manualSend(session.setting) }
                        .disabled(!link.ready || link.busy)
                    HStack {
                        Button("Nudge nearer") { session.nudge(-0.015) }
                        Spacer()
                        Button("Nudge farther") { session.nudge(0.015) }
                    }
                    .buttonStyle(.borderless)
                    .disabled(!link.ready || link.busy)
                    Text(session.manualMessage).font(.footnote).foregroundStyle(.secondary)
                    if !session.verifiedPull {
                        Text("While recording, send three commands in an A–B–A sequence. Check that the lens returns to the original sharp target.")
                            .font(.footnote).foregroundStyle(.secondary)
                        Button("Confirm the lens returned to A", action: session.confirmPull)
                            .disabled(!session.canVerifyPull)
                    }
                }
                Section("Calibrate at a fixed zoom") {
                    Text("Aim the center of the phone at a flat target. Send a command, check sharpness on the Blackmagic, then save the mark. Repeat at different distances.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if let frame = session.frame {
                        Image(decorative: frame.image, scale: 1)
                            .resizable()
                            .scaledToFill()
                            .frame(height: 120)
                            .frame(maxWidth: .infinity)
                            .clipped()
                            .overlay { Image(systemName: "plus").font(.title2).foregroundStyle(accent) }
                            .accessibilityHidden(true)
                    }
                    LabeledContent("Center LiDAR", value: session.calibrationDepth.map {
                        $0.formatted(.number.precision(.fractionLength(2))) + " m"
                    } ?? "Unavailable")
                    Button("Save distance and focus", action: session.saveMark)
                        .disabled(session.calibrationDepth == nil || session.lastManualCommand == nil || link.busy)
                    ForEach(session.profile.marks) { mark in
                        LabeledContent(mark.meters.formatted(.number.precision(.fractionLength(2))) + " m",
                                       value: mark.command.formatted(.number.precision(.fractionLength(3))))
                            .swipeActions {
                                Button("Delete", role: .destructive) { session.removeMark(mark.id) }
                            }
                            .accessibilityAction(named: Text("Delete mark")) { session.removeMark(mark.id) }
                    }
                }
            }
            .navigationTitle("Lens setup")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showLens = false } } }
        }
    }
}
