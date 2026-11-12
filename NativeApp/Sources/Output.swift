import Foundation
import Combine
import Darwin

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
    static func motion(slot: Int, sequence: UInt32, timestamp: UInt64, accel: [Double], gyro: [Double], battery: Int?) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: 80)
        b.replaceSubrange(0..<12, with: info(slot:slot,active:true,battery:battery)); b[11] = 1
        put(sequence, into: &b, at: 12)
        for i in 20..<24 { b[i] = 128 }
        put(timestamp, into: &b, at: 48)
        // DSU expects accel XYZ, then gyro pitch/yaw/roll. For the
        // output XYZ rotation vector this is X/Z/Y respectively.
        let axes = accel + [gyro[0],gyro[2],gyro[1]]
        for i in 0..<6 { put(Float(axes[i]).bitPattern, into: &b, at: 56+i*4) }
        return b
    }
}

final class MotionOutput: ObservableObject {
    @Published var dsuEnabled = false
    @Published var jsonEnabled = false
    @Published var status = "输出已关闭"
    @Published var clientCount = 0
    @Published var sent = 0
    @Published var jsonPort = 8765
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
    private struct Client { var address: sockaddr_in; var slots: [Int:Double] }
    private var clients = [String:Client]()
    private var sentCount = 0
    private var lastUI = 0.0
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
    func shutdown() { stop(); setRumble(false); if jsonFD >= 0 { Darwin.close(jsonFD); jsonFD = -1 } }
    private func active(_ state: ControllerState?) -> Bool {
        guard let state else { return false }
        return !state.demo && state.connected && state.streaming && state.calibration.ready && !state.calibrating && ProcessInfo.processInfo.systemUptime-state.lastArrival < 0.5
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
                    let state = lookup?(Int(slot))
                    let payload = DSUCodec.info(slot:Int(slot),active:active(state),battery:state?.battery)
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
    func publish(_ state: ControllerState) {
        guard !state.demo else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if jsonEnabled {
            if jsonFD < 0 { jsonFD = Darwin.socket(AF_INET,SOCK_DGRAM,0) }
            if jsonFD >= 0 {
                let value: [String:Any] = ["hand":state.hand == .left ? "left" : "right", "device":state.hand.uuid.uuidString,
                    "timestamp_us":state.timestampUS,"raw_axes":state.outputRaw,
                    "accel_g":state.outputAccel,"gyro_dps":state.outputGyro,"calibrated":state.calibration.ready]
                if let data = try? JSONSerialization.data(withJSONObject:value) {
                    var target = sockaddr_in(); target.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); target.sin_family = sa_family_t(AF_INET)
                    target.sin_addr.s_addr = inet_addr("127.0.0.1"); target.sin_port = UInt16(jsonPort).bigEndian
                    send([UInt8](data),to:target,socket:jsonFD)
                }
            }
        }
        clients = clients.filter { $0.value.slots.values.contains { now-$0 < 5 } }
        if dsuEnabled && active(state) {
            let slot = state.hand.rawValue; sequences[slot] &+= 1
            let payload = DSUCodec.motion(slot:slot,sequence:sequences[slot],timestamp:state.timestampUS,accel:state.outputAccel,gyro:state.outputGyro,battery:state.battery)
            let packet = DSUCodec.packet(type:0x100002,payload:payload,serverID:serverID)
            for client in clients.values {
                if let seen = client.slots[slot], now-seen < 5 { send(packet,to:client.address); sentCount += 1 }
            }
        }
        if now-lastUI >= 1 { clientCount = clients.count; sent = sentCount; lastUI = now }
    }
}
