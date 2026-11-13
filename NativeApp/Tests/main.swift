import Foundation

func check(_ condition: @autoclosure () -> Bool, _ message:String) {
    if !condition() { fatalError("FAIL: \(message)") }
}
var checked = 0
for name in ["mac-left-stream.jsonl","mac-right-stream.jsonl"] {
    for line in try String(contentsOfFile:name,encoding:.utf8).split(separator:"\n") {
        let event = try JSONSerialization.jsonObject(with:Data(line.utf8)) as! [String:Any]
        guard let expected = event["motion"] as? [String:Any], let hex = event["hex"] as? String else { continue }
        let bytes = stride(from:0,to:hex.count,by:2).map { i -> UInt8 in
            let start = hex.index(hex.startIndex,offsetBy:i)
            return UInt8(hex[start..<hex.index(start,offsetBy:2)],radix:16)!
        }
        let valid = expected["valid"] as! Bool
        let decoded = MotionFrame.decode(Data(bytes))
        check((decoded != nil) == valid,"invalid-sample filtering")
        if let decoded {
            let raw = (expected["raw_axes"] as! [NSNumber]).map(\.doubleValue)
            check(decoded.raw == raw,"raw axes")
            check(decoded.counter == (expected["counter"] as! NSNumber).uint32Value,"counter")
        }
        checked += 1
    }
}
check(MotionFrame.decode(Data([0x11,6,0])) == nil,"truncated motion")
check(MotionFrame.decode(Data(repeating:0,count:19)) == nil,"wrong prefix")

let motion = DSUCodec.motion(slot:1,sequence:42,timestamp:1234567,accel:[1,2,3],gyro:[4,5,6],battery:98)
let packet = DSUCodec.packet(type:0x100002,payload:motion,serverID:123)
check(packet.count == 100,"DSU size")
check(DSUCodec.u16(packet,6) == 84,"DSU length field")
check(packet[20] == 1 && packet[21] == 2 && packet[31] == 1,"slot/connected fields")
check(Array(packet[40..<44]) == [128,128,128,128],"neutral sticks")
check(Float(bitPattern:DSUCodec.u32(packet,76)) == 1,"acceleration placement")
check(Float(bitPattern:DSUCodec.u32(packet,88)) == 4,"pitch placement")
check(Float(bitPattern:DSUCodec.u32(packet,92)) == 6,"yaw placement")
check(Float(bitPattern:DSUCodec.u32(packet,96)) == 5,"roll placement")
let keys = PairButtons(pressed:[0,12,126,36])
let keyPayload = DSUCodec.motion(slot:0,sequence:1,timestamp:1,accel:[0,0,1],gyro:[0,0,0],battery:nil,buttons:keys)
check(keyPayload[16] == 0x18 && keyPayload[17] == 0x24,"keyboard button bitmasks")
check(keyPayload[27] == 255 && keyPayload[30] == 255 && keyPayload[33] == 255,"keyboard analog button values")
check(keyPayload[28] == 0 && keyPayload[34] == 0,"unpressed buttons")
check(MotionOutput.outputSlot(hand:0,pairMode:true,mixHands:true,target:1) == 1 && MotionOutput.outputSlot(hand:1,pairMode:true,mixHands:true,target:1) == 1,"both hands route to target slot")
check(MotionOutput.outputSlot(hand:1,pairMode:true,mixHands:false,target:0) == 1 && MotionOutput.outputSlot(hand:1,pairMode:false,mixHands:true,target:0) == 1,"normal slot routing")
var request = DSUCodec.packet(type:0x100002,payload:[1,0,0,0,0,0,0,0],serverID:9)
request.replaceSubrange(0..<4,with:Array("DSUC".utf8)); DSUCodec.put(UInt32(0),into:&request,at:8)
DSUCodec.put(DSUCodec.crc(request),into:&request,at:8)
check(DSUCodec.request(request) != nil,"valid client CRC")
check(DSUCodec.request(Array(request.dropLast())) == nil,"truncated request")
request[22] ^= 1
check(DSUCodec.request(request) == nil,"corrupt request CRC")
check(DSUCodec.crc(Array("123456789".utf8)) == 0xCBF43926,"CRC32 known vector")

var calibration = Calibration()
calibration.accelBias = [10,20,30]; calibration.accelScale = [1000,2000,4000]
calibration.gyroBias = [1,2,3]; calibration.gyroScale = [2,4,8]
let converted = calibration.convert([1010,4020,-3970,21,42,83])
check(converted.accel == [1,2,-1] && converted.gyro == [10,10,10],"unit conversion")
calibration.mapping = [2,0,1]; calibration.signs = [-1,-1,1]
check(calibration.convert([1010,4020,-3970,21,42,83]).accel == [1,-1,2],"axis mapping")

let state = ControllerState(.left)
state.calibration = Calibration(); state.streaming = true; state.connected = true
var counter:UInt32 = 0
func feed(_ raw:[Double],variation:Double = 0) {
    let now = ProcessInfo.processInfo.systemUptime
    for i in 1...260 {
        var values = raw; values[0] += i%2 == 0 ? variation : -variation
        counter &+= 12
        state.accept(MotionFrame(counter:counter,raw:values),now:now+Double(i)*0.012)
    }
}
state.lastArrival = ProcessInfo.processInfo.systemUptime
state.begin(.zero); feed([0,0,2048,10,-20,30])
check(state.calibration.zeroed && state.calibration.gyroBias == [10,-20,30],"stationary gyro calibration")
for face in 0..<6 {
    var raw = [10.0,20,30,10,-20,30]
    let axis = face/2; let scale = [2100.0,2200,2300][axis]
    raw[axis] += face%2 == 0 ? scale : -scale
    state.begin(.face(face)); feed(raw)
}
check(state.calibration.facesDone,"six-face completion")
check(state.calibration.accelBias == [10,20,30],"six-face bias")
check(state.calibration.accelScale == [2100,2200,2300],"six-face scale")
let bias = state.calibration.gyroBias
state.begin(.zero); feed([0,0,2048,200,200,200],variation:400)
check(state.calibration.gyroBias == bias,"reject movement during calibration")
state.lastArrival = ProcessInfo.processInfo.systemUptime
state.begin(.turn(0,90))
let turnStart = ProcessInfo.processInfo.systemUptime
feed([0,0,2048,bias[0]+90*16.4/3.12,bias[1],bias[2]])
state.finishTurn(now:turnStart+3.2)
check(state.calibration.gyroDone[0] && abs(state.calibration.gyroScale[0]-16.4) < 0.01,"known-angle gyro calibration")
state.lastArrival = ProcessInfo.processInfo.systemUptime
state.begin(.turn(1,90))
feed([0,0,2048,bias[0]+500,bias[1]+500,bias[2]])
state.finishTurn(now:ProcessInfo.processInfo.systemUptime+3.2)
check(!state.calibration.gyroDone[1],"reject multi-axis rotation")
print("PASS: \(checked) real packets, DSU layout/CRC/validation, unit mapping, static/six-face calibration and motion rejection")

if CommandLine.arguments.contains("--serve") {
    let right = ControllerState(.right)
    let output = MotionOutput()
    let states = [state,right]
    for controller in states {
        controller.calibration = Calibration()
        controller.calibration.zeroed = true; controller.calibration.facesDone = true
        controller.calibration.gyroDone = [true,true,true]
        controller.connected = true; controller.streaming = true; controller.demo = false
        controller.onFrame = { output.publish($0) }
    }
    output.lookup = { slot in states.first { $0.hand.rawValue == slot } }
    output.setDSU(true)
    check(output.dsuEnabled,"DSU server bind")
    let timer = Timer.scheduledTimer(withTimeInterval:0.012,repeats:true) { _ in
        counter &+= 12
        for controller in states {
            let raw = [0.0,0,2048,16.4,32.8,49.2]
            controller.outputRaw = raw
            controller.accept(MotionFrame(counter:counter,raw:raw))
        }
    }
    print("DSU test server on 127.0.0.1:26760 for 15 seconds")
    RunLoop.main.run(until:Date().addingTimeInterval(15))
    timer.invalidate(); output.shutdown()
}
