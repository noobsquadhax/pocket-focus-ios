# Pocket Focus

Private prototype for the iPhone 12 Pro, original Blackmagic Pocket Cinema Camera 6K EF, and Sigma 24–70mm f/2.8 DG OS HSM Art EF. It tracks a selected person in the iPhone image and uses rear LiDAR to estimate depth. The phone sends focus commands to the Pocket 6K over Bluetooth. The capture and tracking run on the phone.

## Build and install

On macOS with Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen), run `xcodegen generate` and open `PocketFocus.xcodeproj`. Select your signing team in the target, choose the physical iPhone, and run. The deployment target is iOS 16.

For a Windows-based setup, the private GitHub workflow builds and tests the iOS target on a macOS runner. The artifact contains an unsigned IPA for development sideloading. Follow the official [AltStore Classic Windows installer](https://faq.altstore.io/altstore-classic/how-to-install-altstore-windows) and [sideloading guide](https://faq.altstore.io/altstore-classic/your-altstore). Enter your Apple Account credentials on your own device. Free provisioning normally needs a refresh every seven days.

## Test the camera

1. Enable Bluetooth in the Pocket 6K Setup menu. Put the lens switch in AF. Open Camera in Pocket Focus, pick the camera, and pair with the code shown on the camera.
2. In Lens setup, send an absolute focus command for a near target, then one for a far target, then the original value again. Verify the recorded Pocket 6K image reaches the two distinct planes and returns to the original one. The app can observe a Bluetooth acknowledgment. Optical confirmation comes from the footage.
3. If absolute focus fails, try the separate nearer and farther nudges to diagnose relative support. The app requires repeatable absolute positions for calibrated autofocus. It has no relative-only tracking mode or verified EF lens-position readback.
4. Mount the iPhone beside the lens, pointing parallel to it, and choose one fixed zoom setting. Put a flat focus target directly under the phone’s center reticle. Send the focus command that gives the sharpest recorded image there, then save the mark. Repeat at three or more distances that span the intended shot. More marks can improve fit. Recalibrate after moving the mount or changing zoom. Calibration uses phone-referenced depth, with the constant offset absorbed by the marks for this mounting angle.
5. Tap a person in the iPhone preview and choose Start autofocus. Test them walking toward and away from the rig, moving across the frame, turning away, and passing another person. Re-arm after an ambiguous match or unreliable depth. Cues on the phone reflect its own view, which can be wider than the Blackmagic frame.

The app holds the previous lens command when Bluetooth or depth becomes unreliable, after a full target loss, and outside the calibrated distance span. A person can still be misidentified at a tight crossing. The capture path, lens-control response, and fitting quality need device verification.

## Technical sources

- [Swift](https://www.swift.org/) and [XcodeGen](https://github.com/yonaskolb/XcodeGen) are open-source build tools. The app uses the system ARKit, Vision, CoreBluetooth, and SwiftUI frameworks with no bundled third-party tracking model.
- [Blackmagic’s Camera Control Protocol](https://documents.blackmagicdesign.com/DeveloperManuals/BlackmagicCameraControl.pdf) specifies the Bluetooth characteristics, focus packet, and signed fixed-point value. [coral/blackmagic-camera-protocol](https://github.com/coral/blackmagic-camera-protocol) is a cross-reference for the public protocol values.
- [CutePocketRemote](https://github.com/oniongarlic/cutepocketremote) is a GPLv3 desktop reference for Pocket-series Bluetooth control. [blackmagic-usb](https://github.com/SH801/blackmagic-usb) is a reference for the difference between USB and Bluetooth lens behavior on original Pocket 6K EF. Neither is shipped in the app.
- Apple’s [scene depth sample](https://developer.apple.com/documentation/arkit/displaying-a-point-cloud-using-scene-depth), [face detection](https://developer.apple.com/documentation/vision/vndetectfacerectanglesrequest), and [body pose detection](https://developer.apple.com/documentation/vision/detecting-human-body-poses-in-images) document the on-device APIs.
