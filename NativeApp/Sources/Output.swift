import Foundation
import Combine
import Darwin
import CoreGraphics
import ApplicationServices

struct PairButtons {
    var pressed: Set<UInt16> = []
    func apply(to b: inout [UInt8]) {
        // DSU face names correspond to the physical Switch layout: circle=A.
        let buttons: [(UInt16, Int, UInt8, Int)] = [
            (123,16,0x80,24),(125,16,0x40,25),(124,16,0x20,26),(126,16,0x10,27),
            (36,16,0x08,-1),(15,16,0x04,-1),(3,16,0x02,-1),(51,16,0x01,-1),
            (7,17,0x80,28),(6,17,0x40,29),(0,17,0x20,30),(1,17,0x10,31),
            (14,17,0x08,32),(12,17,0x04,33),(2,17,0x02,34),(13,17,0x01,35)
        ]
        for (key,byte,mask,analog) in buttons where pressed.contains(key) {
            b[byte] |= mask
            if analog >= 0 { b[analog] = 255 }
        }
        if pressed.contains(49) { b[18] = 1 }
    }
}

enum DSUCodec {
    static func u16(_ b: [UInt8], _ p: Int) -> UInt16 { UInt16(b[p]) | UInt16(b[p+1]) << 8 }
    static func u32(_ b: [UInt8], _ p: Int) -> UInt32 { (0..<4).reduce(0) { $0 | UInt32(b[p+$1]) << ($1*8) } }
    static func put<T: FixedWidthInteger>(_ value: T, into b: inout [UInt8], at p: Int) {
        for i in 0..<MemoryLayout<T>.size { b[p+i] = UInt8(truncatingIfNeeded: value >> (i*8)) }
    }
    static func crc(_ b: [UInt8]) -> UInt32 {
        var value: UInt32 = 0xFFFFFFFF
        for byte in b { value ^= UInt32(byte); for _ in 0..<8 { value = (value >> 1) ^ ((value & 1) == 1 ? 0xEDB88320 : 0) } }
        return value ^ 0xFFFFFFFF
    }
    static func packet(type: UInt32, payload: [UInt8], serverID: UInt32) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: 20+payload.count)
        b.replaceSubrange(0..<4, with: Array("DSUS".utf8))
        put(UInt16(1001), into: &b, at: 4); put(UInt16(payload.count+4), into: &b, at: 6)
        put(serverID, into: &b, at: 12); put(type, into: &b, at: 16)
        b.replaceSubrange(20..<b.count, with: payload); put(crc(b), into: &b, at: 8)
        return b
    }
    static func request(_ raw: [UInt8]) -> [UInt8]? {
        guard raw.count >= 20, Array(raw.prefix(4)) == Array("DSUC".utf8), u16(raw,4) <= 1001 else { return nil }
        let length = Int(u16(raw,6))+16
        guard length >= 20, raw.count >= length else { return nil }
        var b = Array(raw.prefix(length)); let received = u32(b,8)
        put(UInt32(0), into: &b, at: 8)
        guard crc(b) == received else { return nil }
        return Array(raw.prefix(length))
    }
    static func mac(_ slot: Int) -> [UInt8] { [0x02,0x57,0x57,0,0,UInt8(slot+1)] }
    static func info(slot: Int, active: Bool, battery: Int?) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: 12); b[0] = UInt8(slot)
        if active {
            b[1] = 2; b[2] = 2; b[3] = 2; b.replaceSubrange(4..<10, with: mac(slot))
            if let level = battery { b[10] = level > 80 ? 5 : level > 50 ? 4 : level > 25 ? 3 : level > 10 ? 2 : 1 }
        }
        return b
    }
    static func motion(slot: Int, sequence: UInt32, timestamp: UInt64, accel: [Double], gyro: [Double], battery: Int?, buttons: PairButtons = PairButtons()) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: 80)
        b.replaceSubrange(0..<12, with: info(slot:slot,active:true,battery:battery)); b[11] = 1
        put(sequence, into: &b, at: 12)
        for i in 20..<24 { b[i] = 128 }
        buttons.apply(to:&b)
        put(timestamp, into: &b, at: 48)
        // DSU expects accel XYZ, then gyro pitch/yaw/roll. For the
        // output XYZ rotation vector this is X/Z/Y respectively.
        let axes = accel + [gyro[0],gyro[2],gyro[1]]
        for i in 0..<6 { put(Float(axes[i]).bitPattern, into: &b, at: 56+i*4) }
        return b
    }
}

final class MotionOutput: ObservableObject {
    @Published var mouseEnabled = false
    @Published var mouseHand = 0
    @Published var mouseSensitivity = 8.0
    @Published var tapThreshold = 1.2
    @Published var invertMouseX = false
    @Published var invertMouseY = false
    @Published var mousePermission = AXIsProcessTrusted()
    private var mouseLastTime = 0.0
    private var tapBaseline: [Double]?
    private var tapArmed = false
    private var lastTap = 0.0
    func refreshPermissions() {
        mousePermission = AXIsProcessTrusted()
        keyboardPermission = CGPreflightListenEventAccess()
    }
    func setMouseMode(_ enabled: Bool) {
        mouseEnabled = enabled
        mouseLastTime = 0; tapBaseline = nil; tapArmed = false
        if enabled && !AXIsProcessTrusted() {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
        mousePermission = AXIsProcessTrusted()
    }
    private func mouseFrame(_ state: ControllerState) {
        guard mouseEnabled, active(state) else { return }
        mousePermission = AXIsProcessTrusted()
        guard mousePermission else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if state.hand.rawValue == mouseHand {
            let dt = mouseLastTime == 0 ? 0 : now - mouseLastTime
            mouseLastTime = now
            guard dt > 0, dt < 0.1, let event = CGEvent(source:nil) else { return }
            let gyro = state.outputGyro
            func filtered(_ v: Double) -> Double { abs(v) < 3 ? 0 : v }
            let dx = filtered(gyro[2]) * dt * mouseSensitivity * (invertMouseX ? -1 : 1)
            let dy = filtered(gyro[0]) * dt * mouseSensitivity * (invertMouseY ? -1 : 1)
            guard dx != 0 || dy != 0 else { return }
            let p = event.location
            CGEvent(mouseEventSource:nil, mouseType:.mouseMoved, mouseCursorPosition:CGPoint(x:p.x + dx,y:p.y + dy), mouseButton:.left)?.post(tap:.cghidEventTap)
        } else {
            let a = state.outputAccel
            guard let baseline = tapBaseline else { tapBaseline = a; return }
            let impact = sqrt(zip(a,baseline).map { pow($0 - $1,2) }.reduce(0,+))
            tapBaseline = zip(a,baseline).map { $1 * 0.95 + $0 * 0.05 }
            if impact < tapThreshold * 0.4 { tapArmed = true }
            if tapArmed && impact > tapThreshold && now - lastTap > 0.4 {
                tapArmed = false; lastTap = now
                if let location = CGEvent(source:nil)?.location {
                    CGEvent(mouseEventSource:nil,mouseType:.leftMouseDown,mouseCursorPosition:location,mouseButton:.left)?.post(tap:.cghidEventTap)
                    CGEvent(mouseEventSource:nil,mouseType:.leftMouseUp,mouseCursorPosition:location,mouseButton:.left)?.post(tap:.cghidEventTap)
                }
            }
        }
    }
    @Published var dsuEnabled = false
    @Published var jsonEnabled = false
    @Published var status = "输出已关闭"
    @Published var clientCount = 0
    @Published var sent = 0
    @Published var jsonPort = 8765
    @Published var pairMode = false
    @Published var pairHand = 0
    @Published var mixHands = false
    @Published var keyboardPermission = CGPreflightListenEventAccess()
    @Published var pressedKeys = "无"
    @Published var rumbleEnabled = false
    @Published var rumbleStatus = "游戏震动接收已关闭"
    var onRumble: ((Hand, Double) -> Void)?
    var lookup: ((Int) -> ControllerState?)?
    private var fd: Int32 = -1
    private var jsonFD: Int32 = -1
    private var source: DispatchSourceRead?
    private var rumbleFD: Int32 = -1
    private var rumbleSource: DispatchSourceRead?
    private let serverID = UInt32.random(in:1...UInt32.max)
    private var sequences = [UInt32](repeating:0,count:2)
    private var timestamps = [UInt64](repeating:0,count:2)
    static func outputSlot(hand: Int, pairMode: Bool, mixHands: Bool, target: Int) -> Int {
        pairMode && mixHands ? target : hand
    }
    private struct Client { var address: sockaddr_in; var slots: [Int:Double] }
    private var clients = [String:Client]()
    private var sentCount = 0
    private var lastUI = 0.0
    private var keyboardTimer: Timer?
    private weak var lastPairState: ControllerState?
    private let pairKeys: [UInt16] = [123,125,124,126,36,15,3,51,7,6,0,1,14,12,2,13,49]
    func setPairMode(_ enabled: Bool) {
        pairMode = enabled
        if enabled && !CGPreflightListenEventAccess() { _ = CGRequestListenEventAccess() }
        keyboardPermission = CGPreflightListenEventAccess()
        keyboardTimer?.invalidate(); keyboardTimer = nil
        if enabled {
            keyboardTimer = Timer.scheduledTimer(withTimeInterval:1.0/60.0,repeats:true) { [weak self] _ in self?.sendKeyboardFrame() }
        } else { pressedKeys = "无"; lastPairState = nil }
    }
    func setDSU(_ enabled: Bool) {
        if !enabled { stop(); return }
        guard fd < 0 else { return }
        let sock = Darwin.socket(AF_INET, SOCK_DGRAM, 0)
        guard sock >= 0 else { status = "无法创建 UDP socket"; return }
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET); address.sin_port = UInt16(26760).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) { pointer in pointer.withMemoryRebound(to:sockaddr.self,capacity:1) { Darwin.bind(sock,$0,socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard result == 0 else { Darwin.close(sock); status = "端口 26760 无法绑定：\(String(cString:strerror(errno)))"; dsuEnabled = false; return }
        _ = fcntl(sock,F_SETFL,O_NONBLOCK)
        fd = sock; dsuEnabled = true; status = "DSU · 127.0.0.1:26760"
        let read = DispatchSource.makeReadSource(fileDescriptor:sock,queue:.main)
        read.setEventHandler { [weak self] in self?.receive() }
        source = read; read.resume()
    }
    func stop() {
        source?.cancel(); source = nil
        if fd >= 0 { Darwin.close(fd); fd = -1 }
        clients = [:]; clientCount = 0; dsuEnabled = false; status = "DSU 已关闭"
    }
    func setRumble(_ enabled: Bool) {
        if !enabled {
            rumbleSource?.cancel(); rumbleSource = nil
            if rumbleFD >= 0 { Darwin.close(rumbleFD); rumbleFD = -1 }
            rumbleEnabled = false; rumbleStatus = "游戏震动接收已关闭"; return
        }
        guard rumbleFD < 0 else { return }
        let sock = Darwin.socket(AF_INET,SOCK_DGRAM,0)
        guard sock >= 0 else { rumbleStatus = "无法创建震动 UDP 接口"; return }
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET); address.sin_port = UInt16(8766).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to:&address) { pointer in pointer.withMemoryRebound(to:sockaddr.self,capacity:1) { Darwin.bind(sock,$0,socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard result == 0 else { Darwin.close(sock); rumbleStatus = "端口 8766 无法绑定：\(String(cString:strerror(errno)))"; return }
        _ = fcntl(sock,F_SETFL,O_NONBLOCK); rumbleFD = sock; rumbleEnabled = true
        rumbleStatus = "接收中 · 127.0.0.1:8766"
        let read = DispatchSource.makeReadSource(fileDescriptor:sock,queue:.main)
        read.setEventHandler { [weak self] in self?.receiveRumble() }
        rumbleSource = read; read.resume()
    }
    private func receiveRumble() {
        while rumbleFD >= 0 {
            var buffer = [UInt8](repeating:0,count:1024)
            let count = buffer.withUnsafeMutableBytes { recv(rumbleFD,$0.baseAddress,$0.count,0) }
            guard count > 0 else { break }
            guard let value = try? JSONSerialization.jsonObject(with:Data(buffer.prefix(count))) as? [String:Any],
                  value["type"] as? String == "rumble", let side = value["hand"] as? String,
                  let number = value["intensity"] as? NSNumber else { continue }
            let intensity = number.doubleValue
            guard intensity.isFinite, intensity >= 0, intensity <= 1,
                  let hand = side == "left" ? Hand.left : side == "right" ? Hand.right : nil else { continue }
            onRumble?(hand,intensity)
        }
    }
    func shutdown() { setMouseMode(false); setPairMode(false); stop(); setRumble(false); if jsonFD >= 0 { Darwin.close(jsonFD); jsonFD = -1 } }
    private func active(_ state: ControllerState?) -> Bool {
        guard let state else { return false }
        return !state.demo && state.connected && state.streaming && !state.calibrating && ProcessInfo.processInfo.systemUptime-state.lastArrival < 0.5
    }
    private func send(_ bytes: [UInt8], to address: sockaddr_in, socket: Int32? = nil) {
        var target = address
        let socket = socket ?? fd
        bytes.withUnsafeBytes { buffer in
            withUnsafePointer(to:&target) { pointer in pointer.withMemoryRebound(to:sockaddr.self,capacity:1) {
                _ = sendto(socket,buffer.baseAddress,buffer.count,0,$0,socklen_t(MemoryLayout<sockaddr_in>.size))
            } }
        }
    }
    private func receive() {
        while fd >= 0 {
            var bytes = [UInt8](repeating:0,count:2048); var address = sockaddr_in()
            var size = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = bytes.withUnsafeMutableBytes { buffer in withUnsafeMutablePointer(to:&address) { pointer in pointer.withMemoryRebound(to:sockaddr.self,capacity:1) { recvfrom(fd,buffer.baseAddress,buffer.count,0,$0,&size) } } }
            guard count > 0 else { break }
            guard let b = DSUCodec.request(Array(bytes.prefix(count))) else { continue }
            let type = DSUCodec.u32(b,16)
            if type == 0x100000 {
                send(DSUCodec.packet(type:type,payload:[0xE9,0x03],serverID:serverID),to:address)
            } else if type == 0x100001, b.count >= 24 {
                let amount = Int(DSUCodec.u32(b,20))
                guard amount <= 4, b.count >= 24+amount else { continue }
                for slot in b[24..<24+amount] where slot < 4 {
                    let mixed = pairMode && mixHands
                    let state: ControllerState? = mixed && Int(slot) == pairHand
                        ? [lookup?(0),lookup?(1)].compactMap { $0 }.first(where: { active($0) })
                        : mixed ? nil : lookup?(Int(slot))
                    let payload = DSUCodec.info(slot:Int(slot),active:(pairMode && Int(slot) == pairHand) || active(state),battery:state?.battery)
                    send(DSUCodec.packet(type:type,payload:payload,serverID:serverID),to:address)
                }
            } else if type == 0x100002, b.count >= 28 {
                let flags = b[20]
                guard flags & ~UInt8(3) == 0 else { continue }
                var slots = Set<Int>()
                if flags == 0 { slots = [0,1] }
                if flags & 1 != 0, b[21] < 2 { slots.insert(Int(b[21])) }
                if flags & 2 != 0 { for slot in 0..<2 where Array(b[22..<28]) == DSUCodec.mac(slot) { slots.insert(slot) } }
                let key = "\(address.sin_addr.s_addr):\(address.sin_port):\(DSUCodec.u32(b,12))"
                var client = clients[key] ?? Client(address:address,slots:[:])
                for slot in slots { client.slots[slot] = ProcessInfo.processInfo.systemUptime }
                clients[key] = client
            }
        }
    }
    private func sendKeyboardFrame() {
        guard pairMode else { return }
        keyboardPermission = CGPreflightListenEventAccess()
        let keys = Set(pairKeys.filter { CGEventSource.keyState(.combinedSessionState,key:CGKeyCode($0)) })
        let labels: [UInt16:String] = [123:"←",125:"↓",124:"→",126:"↑",36:"回车",15:"R",3:"F",51:"删除",7:"X",6:"Z",0:"A",1:"S",14:"E",12:"Q",2:"D",13:"W",49:"空格"]
        let text = keys.sorted().compactMap { labels[$0] }.joined(separator:" ")
        let shown = text.isEmpty ? "无" : text
        if pressedKeys != shown { pressedKeys = shown }
        guard dsuEnabled else { return }
        let state = lastPairState.flatMap { active($0) && (mixHands || $0.hand.rawValue == pairHand) ? $0 : nil }
        sendFrame(slot:pairHand, timestamp:UInt64(ProcessInfo.processInfo.systemUptime * 1_000_000), accel:state?.outputAccel ?? [0,0,1], gyro:state?.outputGyro ?? [0,0,0], battery:state?.battery, buttons:PairButtons(pressed:keys))
    }
    private func sendFrame(slot: Int, timestamp: UInt64, accel: [Double], gyro: [Double], battery: Int?, buttons: PairButtons) {
        let now = ProcessInfo.processInfo.systemUptime
        clients = clients.filter { $0.value.slots.values.contains { now-$0 < 5 } }
        sequences[slot] &+= 1
        timestamps[slot] = max(timestamp, timestamps[slot] &+ 1)
        let payload = DSUCodec.motion(slot:slot,sequence:sequences[slot],timestamp:timestamps[slot],accel:accel,gyro:gyro,battery:battery,buttons:buttons)
        let packet = DSUCodec.packet(type:0x100002,payload:payload,serverID:serverID)
        for client in clients.values {
            if let seen = client.slots[slot], now-seen < 5 { send(packet,to:client.address); sentCount += 1 }
        }
        if now-lastUI >= 1 { clientCount = clients.count; sent = sentCount; lastUI = now }
    }
    func publish(_ state: ControllerState) {
        guard !state.demo else { return }
        mouseFrame(state)
        let now = ProcessInfo.processInfo.systemUptime
        if jsonEnabled {
            if jsonFD < 0 { jsonFD = Darwin.socket(AF_INET,SOCK_DGRAM,0) }
            if jsonFD >= 0 {
                let value: [String:Any] = ["hand":state.hand == .left ? "left" : "right", "device":state.hand.uuid.uuidString,
                    "timestamp_us":state.timestampUS,"raw_axes":state.outputRaw,
                    "accel_g":state.outputAccel,"gyro_dps":state.outputGyro,"calibrated":state.calibration.ready,"usable":true]
                if let data = try? JSONSerialization.data(withJSONObject:value) {
                    var target = sockaddr_in(); target.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); target.sin_family = sa_family_t(AF_INET)
                    target.sin_addr.s_addr = inet_addr("127.0.0.1"); target.sin_port = UInt16(jsonPort).bigEndian
                    send([UInt8](data),to:target,socket:jsonFD)
                }
            }
        }
        clients = clients.filter { $0.value.slots.values.contains { now-$0 < 5 } }
        if dsuEnabled && active(state) {
            let slot = Self.outputSlot(hand:state.hand.rawValue,pairMode:pairMode,mixHands:mixHands,target:pairHand)
            if pairMode && slot == pairHand { lastPairState = state }
            let buttons = pairMode && slot == pairHand ? PairButtons(pressed:Set(pairKeys.filter { CGEventSource.keyState(.combinedSessionState,key:CGKeyCode($0)) })) : PairButtons()
            sendFrame(slot:slot,timestamp:state.timestampUS,accel:state.outputAccel,gyro:state.outputGyro,battery:state.battery,buttons:buttons)
        }
        if now-lastUI >= 1 { clientCount = clients.count; sent = sentCount; lastUI = now }
    }
}
