import Foundation

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}

check(LensPacket.focus(0) == Data([255, 6, 0, 0, 0, 0, 128, 0, 0, 0, 0, 0]), "Near packet")
check(LensPacket.focus(0.5) == Data([255, 6, 0, 0, 0, 0, 128, 0, 0, 4, 0, 0]), "Midpoint packet")
check(LensPacket.focus(1.1) == Data([255, 6, 0, 0, 0, 0, 128, 0, 0, 8, 0, 0]), "Far packet")
check(LensPacket.focus(-0.25, relative: true) == Data([255, 6, 0, 0, 0, 0, 128, 1, 0, 254, 0, 0]), "Relative packet")
check(LensPacket.focus(.nan) == nil, "Invalid focus input")

var profile = LensProfile()
profile.add(meters: 2.0, command: 0.60)
profile.add(meters: 1.0, command: 0.20)
check(!profile.isUsable, "Two marks cannot enable autofocus")
profile.add(meters: 3.5, command: 0.82)
check(profile.isUsable, "Three increasing marks")
check(profile.command(at: 1.0) == 0.20, "Near endpoint")
check(profile.command(at: 3.5) == 0.82, "Far endpoint")
check(abs(profile.command(at: 4.0 / 3.0)! - 0.4) < 1e-9, "Inverse distance interpolation")
check(profile.command(at: 0.9) == nil && profile.command(at: 4) == nil, "No extrapolation")
profile.add(meters: 2.01, command: 0.09)
check(profile.marks.count == 3 && !profile.isUsable, "Replace duplicate and reject nonmonotonic calibration")
let encoded = try JSONEncoder().encode(profile)
let decoded = try JSONDecoder().decode(LensProfile.self, from: encoded)
check(decoded.marks.map(\.id) == profile.marks.map(\.id), "Calibration round trip")

var filter = FocusFilter()
check(abs(filter.update(0.9, startingAt: 0.2) - 0.32) < 1e-9, "Bounded focus slew")
filter.reset()
check(abs(filter.update(0.6, startingAt: 0.5) - 0.562) < 1e-9, "Smooth after re-arm")

let face = CGRect(x: 0.25, y: 0.20, width: 0.06, height: 0.08)
let body = CGRect(x: 0.19, y: 0.20, width: 0.18, height: 0.60)
let original = FocusSubject(id: 0, bounds: body, face: face, depth: 2)
let turned = FocusSubject(id: 1, bounds: body.offsetBy(dx: 0.055, dy: 0), face: nil, depth: 2.1)
let other = FocusSubject(id: 2, bounds: body.offsetBy(dx: 0.29, dy: 0), face: nil, depth: 2)
let overlap = FocusSubject(id: 3, bounds: body.offsetBy(dx: 0.065, dy: 0), face: nil, depth: 2.1)
let distant = FocusSubject(id: 4, bounds: body, face: face, depth: 3.2)
check(FocusSubject.match(original, in: [other, turned])?.id == 1, "Body fallback on the same subject")
check(FocusSubject.match(original, in: [overlap, turned]) == nil, "Hold during ambiguous crossing")
check(FocusSubject.match(original, in: [distant]) == nil, "Reject depth jump")
check(FocusSubject.match(original, in: []) == nil, "No stale target")
print("Pocket Focus core checks passed")
