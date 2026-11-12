import Foundation
import Combine

enum Hand: Int, CaseIterable, Identifiable {
    case left = 0, right = 1
    var id: Int { rawValue }
    var title: String { self == .left ? "左手柄" : "右手柄" }
    var name: String { self == .left ? "MRR_Boxing_Left" : "MRR_Boxing_Right" }
    var uuid: UUID { UUID(uuidString: self == .left ? "36DD541D-4D8C-3E12-3333-A75D12A06B3C" : "FAA399E8-4DCE-2FA2-5791-37DC6DC43DC0")! }
}

struct MotionFrame {
    let counter: UInt32
    let raw: [Double]
    static func decode(_ data: Data) -> MotionFrame? {
        let b = [UInt8](data)
        guard b.count == 19, Array(b.prefix(3)) == [0x11, 6, 0] else { return nil }
        let counter = UInt32(b[3]) | UInt32(b[4]) << 8 | UInt32(b[5]) << 16 | UInt32(b[6]) << 24
        let values = (0..<6).map { i -> Double in
            let p = 7 + i * 2
            return Double(Int16(bitPattern: UInt16(b[p]) | UInt16(b[p+1]) << 8))
        }
        guard !values.contains(-32768) else { return nil }
        return MotionFrame(counter: counter, raw: values)
    }
}

struct Calibration: Codable {
    var accelBias = [Double](repeating: 0, count: 3)
    var accelScale = [Double](repeating: 2048, count: 3)
    var gyroBias = [Double](repeating: 0, count: 3)
    var gyroScale = [Double](repeating: 16.4, count: 3)
    var zeroed = false
    var facesDone = false
    var gyroDone = [false, false, false]
    // A single orthogonal sensor-to-output mapping applies to both vectors.
    var mapping = [0, 1, 2]
    var signs = [1.0, 1.0, 1.0]
    var ready: Bool { zeroed && facesDone && gyroDone.allSatisfy { $0 } }
    func convert(_ raw: [Double]) -> (accel: [Double], gyro: [Double]) {
        let a = (0..<3).map { (raw[$0] - accelBias[$0]) / accelScale[$0] }
        let g = (0..<3).map { (raw[$0+3] - gyroBias[$0]) / gyroScale[$0] }
        return ((0..<3).map { a[mapping[$0]] * signs[$0] }, (0..<3).map { g[mapping[$0]] * signs[$0] })
    }
}

enum CalibrationWork {
    case zero
    case face(Int)
    case turn(Int, Double)
}

final class ControllerState: ObservableObject, Identifiable {
    let hand: Hand
    var id: Int { hand.rawValue }
    @Published var status = "未连接"
    @Published var connected = false
    @Published var streaming = false
    @Published var battery: Int?
    @Published var raw = [Double](repeating: 0, count: 6)
    @Published var accel = [Double](repeating: 0, count: 3)
    @Published var gyro = [Double](repeating: 0, count: 3)
    @Published var angles = [Double](repeating: 0, count: 3)
    @Published var history = [[Double]]()
    @Published var packets = 0
    @Published var hz = 0.0
    @Published var message = "请先连接手柄。"
    @Published var calibration: Calibration
    @Published var progress = 0.0
    @Published var calibrating = false
    @Published var turning = false
    @Published var faces = [Int: [Double]]()
    @Published var turnAxis = 0
    @Published var turnDegrees = 90.0
    var demo = false
    var remainingCalibration: String {
        var stages = [String]()
        if !calibration.zeroed { stages.append("静置") }
        if !calibration.facesDone { stages.append("六面") }
        if !calibration.gyroDone.allSatisfy({ $0 }) { stages.append("三轴转角") }
        return stages.joined(separator:" / ")
    }
    var lastArrival = 0.0
    var timestampUS: UInt64 = 0
    var onFrame: ((ControllerState) -> Void)?
    private var work: CalibrationWork?
    private var samples = [[Double]]()
    private var workStart = 0.0
    private var integral = [Double](repeating: 0, count: 3)
    private var lastCounter: UInt32?
    private var rateStart = 0.0
    private var ratePackets = 0
    private var lastPublish = 0.0
    private var filteredAngles = [Double](repeating: 0, count: 3)
    private var fusionReady = false
    private var centerAngles = [Double](repeating:0,count:3)

    init(_ hand: Hand) {
        self.hand = hand
        if let data = UserDefaults.standard.data(forKey: "calibration.\(hand.rawValue)"), let saved = try? JSONDecoder().decode(Calibration.self, from: data) {
            calibration = saved
        } else { calibration = Calibration() }
        message = calibration.zeroed ? "已载入静置校准；继续完成六面与三轴转角校准。" : "连接真实手柄后，按下面的顺序校准。"
    }
    func saveCalibration() {
        if let data = try? JSONEncoder().encode(calibration) { UserDefaults.standard.set(data, forKey: "calibration.\(hand.rawValue)") }
    }
    func resetCalibration() {
        cancelCalibration()
        calibration = Calibration(); faces = [:]; fusionReady = false; saveCalibration()
        message = "已重置。物理单位恢复为估算；请重新校准。"
    }
    func recenter() { centerAngles = filteredAngles; angles = [0,0,0] }
    func disconnected() {
        connected = false; streaming = false; hz = 0; battery = nil
        lastCounter = nil; fusionReady = false; centerAngles = [0,0,0]; rateStart = 0; ratePackets = 0
        cancelCalibration()
    }
    func begin(_ job: CalibrationWork) {
        guard streaming && !demo && ProcessInfo.processInfo.systemUptime - lastArrival < 0.5 else {
            message = "请先连接真实手柄，等待连续数据。"; return
        }
        if case .turn = job, !calibration.zeroed { message = "请先完成静置校准。"; return }
        work = job; workStart = ProcessInfo.processInfo.systemUptime
        samples = []; integral = [0,0,0]; progress = 0; calibrating = true
        if case .turn = job { turning = true } else { turning = false }
        switch job {
        case .zero: message = "保持手柄静止 3 秒…"
        case .face: message = "保持当前朝向静止 3 秒…"
        case .turn: message = "缓慢、单方向转动指定角度，完成后点「结束转角」。"
        }
    }
    func cancelCalibration() { work = nil; calibrating = false; turning = false; progress = 0 }
    func finishTurn(now: Double = ProcessInfo.processInfo.systemUptime) {
        guard case let .turn(axis, degrees) = work else { return }
        let elapsed = now - workStart
        let chosen = abs(integral[axis])
        let cross = (0..<3).filter { $0 != axis }.map { abs(integral[$0]) }.max() ?? 0
        guard elapsed >= 1, samples.count >= 50, chosen > 90, cross < chosen * 0.45 else {
            message = "旋转不足，或绕了多条轴。请选对 G 轴，单方向旋转后重试。"; cancelCalibration(); return
        }
        let scale = chosen / degrees
        guard scale > 0.1 && scale < 10000 else { message = "旋转结果异常，请重试。"; cancelCalibration(); return }
        calibration.gyroScale[axis] = scale; calibration.gyroDone[axis] = true
        saveCalibration(); message = "G\(["X","Y","Z"][axis]) 转角比例已保存：\(String(format: "%.3f", scale)) count/(°/s)。"
        cancelCalibration(); recenter()
    }
    private func finishStationary(_ job: CalibrationWork) {
        guard samples.count >= 120 else { message = "有效采样不足，请重试。"; cancelCalibration(); return }
        let mean = (0..<6).map { i in samples.map { $0[i] }.reduce(0,+) / Double(samples.count) }
        let sd = (0..<6).map { i in sqrt(samples.map { pow($0[i]-mean[i],2) }.reduce(0,+) / Double(samples.count)) }
        guard sd.prefix(3).max()! < 70, sd.suffix(3).max()! < 140 else {
            message = "检测到移动，未保存。请放在固定表面重试。"; cancelCalibration(); return
        }
        switch job {
        case .zero:
            calibration.gyroBias = Array(mean.suffix(3)); calibration.zeroed = true
            message = "静置校准已保存。下一步：六面和三轴转角校准。"
        case let .face(face):
            let axis = face / 2; let sign = face % 2 == 0 ? 1.0 : -1.0
            let norm = sqrt(mean.prefix(3).map { $0*$0 }.reduce(0,+))
            guard norm > 500, mean[axis] * sign / norm > 0.90 else {
                message = "朝向不匹配。让 A\(["X","Y","Z"][axis]) 处于\(sign > 0 ? "正" : "负")方向且幅值最大，再采集。"; cancelCalibration(); return
            }
            faces[face] = Array(mean.prefix(3))
            if faces.count == 6 {
                var bias = [Double](); var scale = [Double]()
                for i in 0..<3 {
                    let plus = faces[i*2]![i]; let minus = faces[i*2+1]![i]
                    bias.append((plus+minus)/2); scale.append((plus-minus)/2)
                }
                guard scale.allSatisfy({ $0 > 200 && $0 < 20000 }) else { message = "六面跨度异常，请重新采集。"; cancelCalibration(); return }
                calibration.accelBias = bias; calibration.accelScale = scale; calibration.facesDone = true
                message = "六面校准完成，加速度零偏和每轴比例已保存。"
            } else { message = "已采集 \(faces.count)/6 个朝向。" }
        case .turn: break
        }
        saveCalibration(); cancelCalibration(); recenter()
    }
    func accept(_ frame: MotionFrame, now: Double = ProcessInfo.processInfo.systemUptime) {
        outputRaw = frame.raw
        let dt: Double
        if let last = lastCounter { dt = min(0.1, Double(frame.counter &- last) / 1000) } else { dt = 0.012 }
        lastCounter = frame.counter; lastArrival = now
        timestampUS = UInt64(now * 1_000_000)
        let values = calibration.convert(frame.raw)
        if let job = work {
            samples.append(frame.raw)
            for i in 0..<3 { integral[i] += (frame.raw[i+3] - calibration.gyroBias[i]) * dt }
            let elapsed = now - workStart
            switch job {
            case .turn:
                if elapsed > 30 { message = "转角校准超时，请重新开始。"; cancelCalibration() }
            default:
                progress = min(1, elapsed/3)
                if elapsed >= 3 { finishStationary(job) }
            }
        }
        let a = values.accel; let g = values.gyro
        let roll = atan2(a[1], a[2]) * 180 / .pi
        let pitch = atan2(-a[0], hypot(a[1],a[2])) * 180 / .pi
        if !fusionReady { filteredAngles = [roll,pitch,0]; fusionReady = true }
        else {
            for i in 0..<3 { filteredAngles[i] += g[i] * dt }
            let norm = sqrt(a.map { $0*$0 }.reduce(0,+))
            if norm > 0.75 && norm < 1.25 {
                let weight = 1 - exp(-dt/0.5)
                // Wrap differences to avoid jumps at ±180°.
                func delta(_ target: Double, _ current: Double) -> Double { var d = (target-current).truncatingRemainder(dividingBy:360); if d > 180 { d -= 360 }; if d < -180 { d += 360 }; return d }
                filteredAngles[0] += weight * delta(roll,filteredAngles[0])
                filteredAngles[1] += weight * delta(pitch,filteredAngles[1])
            }
        }
        packets += 1; ratePackets += 1
        if rateStart == 0 { rateStart = now }
        if now-rateStart >= 1 { hz = Double(ratePackets)/(now-rateStart); rateStart = now; ratePackets = 0 }
        // Output each sensor sample; refresh the interface at ~30 Hz.
        if now-lastPublish >= 1/30 {
            raw = frame.raw; accel = a; gyro = g; angles = (0..<3).map { filteredAngles[$0]-centerAngles[$0] }
            history.append(frame.raw); if history.count > 150 { history.removeFirst(history.count-150) }
            streaming = true; status = demo ? "演示数据" : "实时采集"; lastPublish = now
        }
        onFrame?(self)
    }
    // Output must use the current packet, not the throttled UI sample.
    var outputRaw = [Double](repeating: 0, count: 6)
    var outputAccel: [Double] { calibration.convert(outputRaw).accel }
    var outputGyro: [Double] { calibration.convert(outputRaw).gyro }
}
