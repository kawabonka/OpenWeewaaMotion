import Foundation
import CoreBluetooth
import Combine

final class MotionManager: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    let controllers = Hand.allCases.map(ControllerState.init)
    let output = MotionOutput()
    @Published var bluetoothStatus = "点击连接以开启蓝牙"
    @Published var bluetoothUnauthorized = false
    @Published var demo = false
    @Published var log = [String]()
    private var central: CBCentralManager?
    private var wanted = Set<Hand>()
    private var peripherals = [UUID:CBPeripheral]()
    private var sides = [UUID:Hand]()
    private var writers = [UUID:CBCharacteristic]()
    private var tokens = [UUID:UUID]()
    private var timers: Timer?
    private var demoTimer: Timer?
    private var lastKeepalive = 0.0
    private var lastRumble = [Hand:Double]()
    private let service = CBUUID(string:"AE30")
    private let tx = CBUUID(string:"AE01")
    private let rx = CBUUID(string:"AE02")
    override init() {
        super.init()
        output.lookup = { [weak self] slot in self?.controllers.first { $0.hand.rawValue == slot } }
        output.onRumble = { [weak self] hand,intensity in self?.vibrate(hand,intensity:intensity) }
        for state in controllers { state.onFrame = { [weak self] in self?.output.publish($0) } }
    }
    func note(_ text: String) {
        log.append(text); if log.count > 12 { log.removeFirst() }
    }
    func vibrate(_ hand: Hand, intensity: Double = 1) {
        // Only this exact factory pulse has been physically verified. The
        // amplitude/frequency/duration byte meanings are still unknown.
        guard intensity > 0.05, !demo, !controllers[hand.rawValue].calibrating else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now-(lastRumble[hand] ?? -1) >= 0.25 else { return }
        guard let peripheral = peripherals.values.first(where:{ sides[$0.identifier] == hand && $0.state == .connected }),
              let writer = writers[peripheral.identifier] else { note("\(hand.title) 未连接，无法震动"); return }
        peripheral.writeValue(Data([0x82,0x50,0x96,0x96]),for:writer,type:.withoutResponse)
        lastRumble[hand] = now
        note("\(hand.title) · 已发送原厂震动脉冲")
    }
    func connectBoth() { for hand in Hand.allCases { connect(hand) } }
    func connect(_ hand: Hand) {
        if demo { setDemo(false) }
        wanted.insert(hand); controllers[hand.rawValue].status = "等待蓝牙…"
        if central == nil { central = CBCentralManager(delegate:self,queue:.main) }
        else if central?.state == .poweredOn { find(hand) }
        if timers == nil { timers = Timer.scheduledTimer(withTimeInterval:1,repeats:true) { [weak self] _ in self?.tick() } }
    }
    private func find(_ hand: Hand) {
        guard let central, !peripherals.values.contains(where:{ sides[$0.identifier] == hand && ($0.state == .connected || $0.state == .connecting) }) else { return }
        controllers[hand.rawValue].status = "正在寻找…"
        let cached = central.retrievePeripherals(withIdentifiers:[hand.uuid])
        if let peripheral = cached.first { attach(peripheral,hand:hand) }
        central.scanForPeripherals(withServices:[service],options:nil)
    }
    private func attach(_ peripheral: CBPeripheral, hand: Hand) {
        guard wanted.contains(hand), peripheral.state != .connecting else { return }
        if let existing = peripherals.values.first(where:{ sides[$0.identifier] == hand && ($0.state == .connected || $0.state == .connecting) }) {
            if existing.identifier != peripheral.identifier { return }
        }
        peripherals[peripheral.identifier] = peripheral; sides[peripheral.identifier] = hand
        peripheral.delegate = self; controllers[hand.rawValue].status = "连接中…"
        central?.connect(peripheral,options:nil)
    }
    func disconnect(_ hand: Hand) {
        wanted.remove(hand)
        for (id,peripheral) in peripherals where sides[id] == hand {
            tokens.removeValue(forKey:id); writers.removeValue(forKey:id); central?.cancelPeripheralConnection(peripheral)
        }
        controllers[hand.rawValue].disconnected(); controllers[hand.rawValue].status = "未连接"
        if wanted.isEmpty { central?.stopScan() }
    }
    func disconnectAll() { for hand in Hand.allCases { disconnect(hand) }; setDemo(false) }
    func shutdown() { disconnectAll(); timers?.invalidate(); demoTimer?.invalidate(); output.shutdown() }
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        bluetoothUnauthorized = central.state == .unauthorized
        switch central.state {
        case .poweredOn: bluetoothStatus = "蓝牙就绪"; for hand in wanted { find(hand) }
        case .poweredOff: bluetoothStatus = "请在系统中开启蓝牙"; for state in controllers { state.disconnected(); state.status = "蓝牙关闭" }
        case .unauthorized: bluetoothStatus = "请在系统设置 → 隐私与安全性 → 蓝牙中允许 WeeWaa Motion"
        case .unsupported: bluetoothStatus = "当前环境无法访问蓝牙"
        default: bluetoothStatus = "蓝牙初始化中…"
        }
    }
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String:Any], rssi RSSI: NSNumber) {
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? ""
        if let hand = Hand.allCases.first(where:{ $0.name == name }), wanted.contains(hand), peripherals[peripheral.identifier]?.state != .connected {
            attach(peripheral,hand:hand)
        }
    }
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard let hand = sides[peripheral.identifier] else { return }
        controllers[hand.rawValue].connected = true; controllers[hand.rawValue].status = "发现服务…"
        note("\(hand.title) 已连接")
        peripheral.discoverServices([service,CBUUID(string:"180F")])
        if wanted.allSatisfy({ controllers[$0.rawValue].connected }) { central.stopScan() }
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        fail(peripheral,error?.localizedDescription ?? "连接失败，请确认已从 iPad 断开")
    }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard let hand = sides[peripheral.identifier] else { return }
        tokens.removeValue(forKey:peripheral.identifier); writers.removeValue(forKey:peripheral.identifier)
        controllers[hand.rawValue].disconnected(); controllers[hand.rawValue].status = error?.localizedDescription ?? "已断开"
        note("\(hand.title) 已断开")
        // Reconnection is explicit so disconnecting a device elsewhere does not
        // create a reconnection race with the iPad app.
    }
    private func fail(_ peripheral: CBPeripheral, _ text: String) {
        guard let hand = sides[peripheral.identifier] else { return }
        controllers[hand.rawValue].status = text; note("\(hand.title)：\(text)")
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error { fail(peripheral,error.localizedDescription); return }
        for service in peripheral.services ?? [] {
            peripheral.discoverCharacteristics(service.uuid == self.service ? [tx,rx] : [CBUUID(string:"2A19")],for:service)
        }
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error { fail(peripheral,error.localizedDescription); return }
        for characteristic in service.characteristics ?? [] {
            if characteristic.uuid == tx { writers[peripheral.identifier] = characteristic }
            if characteristic.uuid == rx { peripheral.setNotifyValue(true,for:characteristic) }
            if characteristic.uuid == CBUUID(string:"2A19") { peripheral.readValue(for:characteristic) }
        }
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error { fail(peripheral,error.localizedDescription); return }
        guard characteristic.uuid == rx, characteristic.isNotifying else { return }
        let id = peripheral.identifier; let token = UUID(); tokens[id] = token
        let commands: [(Double,[UInt8])] = [(0.9,[0x29]),(1.14,[0x60]),(1.54,[0x60]),(1.92,[0x46]),(2.92,[0x12,0x64,0xFF,0x19,4,0x50,1,3,5,7,0])]
        for (delay,bytes) in commands {
            DispatchQueue.main.asyncAfter(deadline:.now()+delay) { [weak self,weak peripheral] in
                guard let self, let peripheral, self.tokens[id] == token, peripheral.state == .connected,
                      let writer = self.writers[id] else { return }
                peripheral.writeValue(Data(bytes),for:writer,type:.withoutResponse)
            }
        }
        if let hand = sides[id] { controllers[hand.rawValue].status = "开启传感器…" }
        DispatchQueue.main.asyncAfter(deadline:.now()+8) { [weak self] in
            guard let self, self.tokens[id] == token, let hand = self.sides[id], !self.controllers[hand.rawValue].streaming else { return }
            self.controllers[hand.rawValue].status = "未收到体感，请断开后重连"
        }
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let hand = sides[peripheral.identifier], let data = characteristic.value else { return }
        let state = controllers[hand.rawValue]
        if characteristic.uuid == CBUUID(string:"2A19"), let level = data.first { state.battery = Int(level); return }
        if characteristic.uuid == rx, let frame = MotionFrame.decode(data) { state.outputRaw = frame.raw; state.accept(frame) }
    }
    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        if now-lastKeepalive >= 3 {
            for (id,writer) in writers {
                if let peripheral = peripherals[id], peripheral.state == .connected { peripheral.writeValue(Data([0x19]),for:writer,type:.withoutResponse) }
            }
            lastKeepalive = now
        }
        for state in controllers where state.connected && state.streaming && !state.demo && now-state.lastArrival > 1 {
            state.streaming = false; state.hz = 0; state.status = "数据已暂停，请重连"
            state.cancelCalibration()
        }
    }
    func setDemo(_ enabled: Bool) {
        demoTimer?.invalidate(); demoTimer = nil
        if enabled {
            for hand in Hand.allCases { disconnect(hand) }
            demo = true; for state in controllers { state.demo = true; state.recenter() }
            let start = ProcessInfo.processInfo.systemUptime
            demoTimer = Timer.scheduledTimer(withTimeInterval:1/60,repeats:true) { [weak self] _ in
                guard let self else { return }
                let t = ProcessInfo.processInfo.systemUptime-start
                for state in self.controllers {
                    let phase = t+Double(state.hand.rawValue)*1.4
                    let roll = 0.6*sin(phase); let pitch = 0.45*cos(phase*0.7)
                    let a = [-sin(pitch),sin(roll)*cos(pitch),cos(roll)*cos(pitch)]
                    let g = [0.6*cos(phase)*180 / Double.pi,-0.315*sin(phase*0.7)*180 / Double.pi,15*sin(phase*0.4)]
                    let raw = (0..<3).map { a[$0]*state.calibration.accelScale[$0]+state.calibration.accelBias[$0] } + (0..<3).map { g[$0]*state.calibration.gyroScale[$0]+state.calibration.gyroBias[$0] }
                    let frame = MotionFrame(counter:UInt32(t*1000),raw:raw)
                    state.outputRaw = raw; state.accept(frame)
                }
            }
        } else if demo {
            demo = false; for state in controllers { state.demo = false; state.disconnected(); state.status = "未连接" }
        }
    }
}
