import Combine
import CoreBluetooth
import Foundation

final class BlackmagicLink: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    struct Camera: Identifiable {
        let id: UUID
        let name: String
    }

    @Published private(set) var cameras: [Camera] = []
    @Published private(set) var status = "Connect a camera"
    @Published private(set) var ready = false
    @Published private(set) var scanning = false
    @Published private(set) var connecting = false
    @Published private(set) var busy = false
    var onWrite: ((Double?) -> Void)?
    var onReset: (() -> Void)?

    private let service = CBUUID(string: "291D567A-6D75-11E6-8B77-86F30CA893D3")
    private let outgoing = CBUUID(string: "5DD3465F-1AEE-4299-8493-D2ECA2F8E1BB")
    private let cameraStatus = CBUUID(string: "7FE8691D-95DC-4FC5-8ABD-CA74339B51B9")
    private var central: CBCentralManager?
    private var found: [UUID: CBPeripheral] = [:]
    private var active: CBPeripheral?
    private var writeTarget: CBCharacteristic?
    private var pendingAbsolute: Double?
    private var timeout: DispatchWorkItem?
    private var wantsScan = false

    func scan() {
        guard active == nil else { return }
        wantsScan = true
        if let central {
            centralManagerDidUpdateState(central)
        } else {
            central = CBCentralManager(delegate: self, queue: .main)
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            guard wantsScan, active == nil else { return }
            wantsScan = false
            cameras = []
            found = [:]
            scanning = true
            status = "Searching for Blackmagic cameras…"
            central.scanForPeripherals(withServices: [service])
            scheduleTimeout(after: 12) { [weak self] in
                self?.stopScan()
                self?.status = self?.cameras.isEmpty == true ? "No cameras found. Check camera Bluetooth." : "Choose your camera."
            }
        case .poweredOff:
            reset("Turn on Bluetooth.")
        case .unauthorized:
            wantsScan = false
            reset("Allow Bluetooth in Settings.")
        case .unsupported:
            wantsScan = false
            reset("Bluetooth is unavailable on this device.")
        case .resetting:
            reset("Bluetooth is restarting.")
        default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard scanning, found[peripheral.identifier] == nil else { return }
        found[peripheral.identifier] = peripheral
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? peripheral.name ?? String(peripheral.identifier.uuidString.prefix(8))
        cameras.append(Camera(id: peripheral.identifier, name: name))
        status = "Choose your camera."
    }

    func connect(_ id: UUID) {
        guard let peripheral = found[id], active == nil, let central else { return }
        stopScan()
        active = peripheral
        peripheral.delegate = self
        connecting = true
        status = "Connecting to \(peripheral.name ?? "camera")…"
        central.connect(peripheral)
        scheduleTimeout(after: 40) { [weak self] in self?.disconnect("Connection timed out.") }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard peripheral === active else { return }
        peripheral.discoverServices([service])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard peripheral === active else { return }
        reset(error?.localizedDescription ?? "Connection failed.")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard peripheral === active else { return }
        reset("Camera disconnected.")
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard peripheral === active else { return }
        guard error == nil, let match = peripheral.services?.first(where: { $0.uuid == service }) else {
            disconnect("Camera control service unavailable.")
            return
        }
        peripheral.discoverCharacteristics([outgoing, cameraStatus], for: match)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard peripheral === active else { return }
        guard error == nil, let characteristics = service.characteristics,
              let output = characteristics.first(where: { $0.uuid == outgoing }),
              output.properties.contains(.write),
              let pair = characteristics.first(where: { $0.uuid == cameraStatus }) else {
            disconnect("Camera focus control unavailable.")
            return
        }
        writeTarget = output
        status = "Pair using the code on the Pocket 6K."
        peripheral.setNotifyValue(true, for: pair)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === active, characteristic.uuid == cameraStatus else { return }
        guard error == nil, characteristic.isNotifying else {
            disconnect(error?.localizedDescription ?? "Camera pairing failed.")
            return
        }
        timeout?.cancel()
        connecting = false
        ready = true
        status = "Connected · \(peripheral.name ?? "Blackmagic")"
    }

    @discardableResult
    func send(_ value: Double, relative: Bool = false) -> Bool {
        guard ready, !busy, let active, active.state == .connected,
              let writeTarget, let packet = LensPacket.focus(value, relative: relative) else { return false }
        busy = true
        pendingAbsolute = relative ? nil : value
        active.writeValue(packet, for: writeTarget, type: .withResponse)
        scheduleTimeout(after: 2) { [weak self] in self?.disconnect("Focus command timed out.") }
        return true
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === active, characteristic.uuid == outgoing, busy else { return }
        timeout?.cancel()
        let value = pendingAbsolute
        pendingAbsolute = nil
        busy = false
        if let error {
            disconnect(error.localizedDescription)
        } else {
            onWrite?(value)
        }
    }

    func disconnect(_ message: String = "Camera disconnected.") {
        if let active { central?.cancelPeripheralConnection(active) }
        reset(message)
    }

    private func reset(_ message: String) {
        stopScan()
        active = nil
        writeTarget = nil
        pendingAbsolute = nil
        busy = false
        ready = false
        connecting = false
        cameras = []
        found = [:]
        status = message
        onReset?()
    }

    private func stopScan() {
        timeout?.cancel()
        central?.stopScan()
        scanning = false
    }

    private func scheduleTimeout(after seconds: Double, _ action: @escaping () -> Void) {
        timeout?.cancel()
        let work = DispatchWorkItem(block: action)
        timeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }
}
