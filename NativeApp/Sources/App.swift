import SwiftUI
import AppKit

// Use the property-wrapper type explicitly: the installed SDK also exports a
// same-named State macro whose build plugin is absent from Command Line Tools.
private typealias ViewState<Value> = SwiftUI.State<Value>

private let appBackground = Color(red:0.035,green:0.055,blue:0.09)
private let panel = Color(red:0.065,green:0.09,blue:0.14)
private let cyan = Color(red:0.22,green:0.84,blue:0.89)
private let amber = Color(red:1,green:0.66,blue:0.32)
private let axisColors: [Color] = [.red,.green,.blue]

@main struct WeeWaaMotionApp: App {
    @StateObject private var manager = MotionManager()
    var body: some Scene {
        WindowGroup("WeeWaa Motion") {
            MainView(manager:manager).preferredColorScheme(.dark)
                .onAppear {
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate(ignoringOtherApps:true)
                    if ProcessInfo.processInfo.arguments.contains("--connect") { manager.connectBoth() }
                    if ProcessInfo.processInfo.arguments.contains("--demo") { manager.setDemo(true) }
                }
                .onReceive(NotificationCenter.default.publisher(for:NSApplication.didBecomeActiveNotification)) { _ in manager.output.refreshPermissions() }
                .onReceive(NotificationCenter.default.publisher(for:NSApplication.willTerminateNotification)) { _ in manager.shutdown() }
        }.defaultSize(width:1200,height:850)
        .commands { CommandGroup(replacing:.newItem) {} }
    }
}

struct SettingsLink: View {
    let title: String
    let anchor: String
    var body: some View {
        Link(title,destination:URL(string:"x-apple.systempreferences:com.apple.preference.security?\(anchor)")!)
            .font(.system(size:11))
    }
}

struct MainView: View {
    @ObservedObject var manager: MotionManager
    @ViewState private var tab = 0
    @ViewState private var hand = Hand.left
    var body: some View {
        VStack(spacing:0) {
            HStack(spacing:16) {
                Image(systemName:"waveform.path").font(.system(size:27,weight:.medium)).foregroundStyle(cyan)
                    .frame(width:50,height:50).background(cyan.opacity(0.10),in:RoundedRectangle(cornerRadius:15))
                VStack(alignment:.leading,spacing:3) {
                    Text("WeeWaa Motion").font(.system(size:26,weight:.bold,design:.rounded))
                    Text("双手六轴 · 实时体感工作台").font(.system(size:12)).foregroundStyle(.secondary)
                }
                Spacer()
                Button(manager.demo ? "退出演示" : "演示模式") { manager.setDemo(!manager.demo) }.buttonStyle(.bordered)
                Button("连接两只手柄",systemImage:"antenna.radiowaves.left.and.right") { manager.connectBoth() }
                    .buttonStyle(.plain).padding(.horizontal,14).padding(.vertical,9)
                    .background(cyan,in:RoundedRectangle(cornerRadius:9)).foregroundStyle(.black)
                Button { manager.disconnectAll() } label: { Image(systemName:"stop.circle") }.help("断开所有手柄")
            }.padding(24)
            HStack {
                Picker("页面",selection:$tab) {
                    Text("实时仪表").tag(0); Text("传感器校准").tag(1); Text("体感输出").tag(2)
                }.pickerStyle(.segmented).frame(width:360)
                Spacer()
                Circle().fill(manager.demo ? amber : cyan).frame(width:6,height:6)
                BatteryStatus(state:manager.controllers[0])
                BatteryStatus(state:manager.controllers[1])
                Text(manager.demo ? "模拟数据 · 不发送到输出接口" : manager.bluetoothStatus).font(.system(size:11)).foregroundStyle(.secondary)
                if manager.bluetoothUnauthorized { SettingsLink(title:"打开蓝牙权限设置",anchor:"Privacy_Bluetooth") }
            }.padding(.horizontal,26).padding(.bottom,20)
            ScrollView {
                VStack(spacing:18) {
                    if tab == 0 {
                        HStack(alignment:.top,spacing:18) {
                            ForEach(manager.controllers) { state in ControllerCard(state:state,manager:manager) }
                        }
                        HStack {
                            Label("姿态演示为互补滤波估计；航向会漂移，可随时回中。",systemImage:"info.circle")
                            Spacer(); Text("红 X   绿 Y   蓝 Z")
                        }.font(.system(size:11)).foregroundStyle(.secondary)
                    } else if tab == 1 {
                        Picker("手柄",selection:$hand) { ForEach(Hand.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented).frame(width:230)
                        CalibrationView(state:manager.controllers[hand.rawValue])
                    } else { OutputView(output:manager.output,controllers:manager.controllers) }
                }.padding(.horizontal,26).padding(.bottom,24)
            }
            HStack {
                Text(manager.log.last ?? "让手柄保持开机，并从 iPad 原厂 App 断开连接。")
                Spacer(); Text("本机运行 · 校准独立保存")
            }.font(.system(size:10)).foregroundStyle(.secondary).padding(.horizontal,26).padding(.vertical,12)
                .background(.white.opacity(0.025))
        }.background(appBackground).frame(minWidth:1000,minHeight:730)
    }
}

struct BatteryStatus: View {
    @ObservedObject var state: ControllerState
    var compact = false
    var body: some View {
        let title = state.battery.map { "\($0)%" } ?? (state.demo ? "演示" : state.connected ? "读取中" : "未连接")
        Label(compact ? title : "\(state.hand.title) \(title)",systemImage:"battery.100percent")
            .font(.system(size:11,weight:.medium))
            .foregroundStyle((state.battery ?? 100) <= 20 ? Color.orange : Color.secondary)
            .fixedSize().padding(.horizontal,8).padding(.vertical,5)
            .background(.white.opacity(0.04),in:RoundedRectangle(cornerRadius:7))
            .accessibilityLabel("\(state.hand.title)电量：\(title)")
    }
}

struct ControllerCard: View {
    @ObservedObject var state: ControllerState
    let manager: MotionManager
    var tint: Color { state.hand == .left ? cyan : amber }
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            HStack {
                Text(state.hand == .left ? "L" : "R").font(.system(size:17,weight:.heavy,design:.rounded))
                    .foregroundStyle(tint).frame(width:36,height:36).background(tint.opacity(0.12),in:RoundedRectangle(cornerRadius:10))
                VStack(alignment:.leading,spacing:4) {
                    Text(state.hand.title).font(.system(size:17,weight:.semibold))
                    Text(state.status).font(.system(size:11)).foregroundStyle(state.streaming ? tint : .secondary)
                }
                Spacer()
                BatteryStatus(state:state,compact:true)
                Button(state.connected ? "断开" : "连接") { if state.connected { manager.disconnect(state.hand) } else { manager.connect(state.hand) } }.buttonStyle(.bordered)
            }
            HStack(spacing:22) {
                stat(String(format:"%.1f",state.hz),"Hz 采样率")
                stat(state.packets.formatted(),"有效样本")
                Spacer()
                Text(state.calibration.ready ? "已校准" : "量程未校准")
                    .font(.system(size:10,weight:.medium)).foregroundStyle(state.calibration.ready ? cyan : amber)
                    .padding(7).background((state.calibration.ready ? cyan : amber).opacity(0.08),in:Capsule())
            }
            HStack { Text("原厂触觉反馈").font(.system(size:11)).foregroundStyle(.secondary); Spacer(); Button("震动测试",systemImage:"waveform") { manager.vibrate(state.hand) }.buttonStyle(.bordered).disabled(!state.connected || state.demo || state.calibrating) }
            PoseView(angles:state.angles,tint:tint).frame(height:165)
                .background(appBackground.opacity(0.6),in:RoundedRectangle(cornerRadius:14))
                .overlay(alignment:.topLeading) { Text("姿态预览").font(.system(size:10)).foregroundStyle(.secondary).padding(12) }
                .overlay(alignment:.bottomTrailing) { Button("回中") { state.recenter() }.buttonStyle(.borderless).font(.system(size:11)).padding(12) }
            AxisReadout(title:"加速度",unit:state.calibration.facesDone ? "g" : "g · 估算",values:state.accel,raw:Array(state.raw.prefix(3)))
            Waveform(history:state.history,offset:0).frame(height:66)
            AxisReadout(title:"角速度",unit:state.calibration.gyroDone.allSatisfy{$0} ? "°/s" : "°/s · 估算",values:state.gyro,raw:Array(state.raw.suffix(3)))
            Waveform(history:state.history,offset:3).frame(height:66)
        }.padding(20).frame(maxWidth:.infinity).background(panel,in:RoundedRectangle(cornerRadius:22))
            .overlay(RoundedRectangle(cornerRadius:22).stroke(.white.opacity(0.06)))
    }
    func stat(_ value:String,_ label:String) -> some View {
        VStack(alignment:.leading,spacing:3) { Text(value).font(.system(size:21,weight:.semibold,design:.monospaced)); Text(label).font(.system(size:10)).foregroundStyle(.secondary) }
    }
}

struct AxisReadout: View {
    let title:String; let unit:String; let values:[Double]; let raw:[Double]
    var body: some View {
        VStack(alignment:.leading,spacing:9) {
            HStack { Text(title).font(.system(size:12,weight:.semibold)); Spacer(); Text(unit).font(.system(size:10)).foregroundStyle(.secondary) }
            HStack(spacing:10) {
                ForEach(0..<3,id:\.self) { i in
                    VStack(alignment:.leading,spacing:4) {
                        HStack(spacing:5) { Circle().fill(axisColors[i]).frame(width:5,height:5); Text(["X","Y","Z"][i]).font(.system(size:10)); Spacer() }
                        Text(String(format:"%+.2f",values[i])).font(.system(size:18,weight:.medium,design:.monospaced)).minimumScaleFactor(0.6).lineLimit(1)
                        Text("原始 \(Int(raw[i]))").font(.system(size:9,design:.monospaced)).foregroundStyle(.secondary)
                    }.frame(maxWidth:.infinity,alignment:.leading)
                }
            }
        }
    }
}

struct Waveform: View {
    let history:[[Double]]; let offset:Int
    var body: some View {
        Canvas { context,size in
            var grid = Path()
            for i in 0...2 { let y = size.height*Double(i)/2; grid.move(to:CGPoint(x:0,y:y)); grid.addLine(to:CGPoint(x:size.width,y:y)) }
            context.stroke(grid,with:.color(.white.opacity(0.05)),lineWidth:1)
            let scale = max(offset == 0 ? 2500.0 : 1000.0,history.flatMap{ Array($0[offset..<offset+3]) }.map(abs).max() ?? 1)
            for axis in 0..<3 {
                var path = Path()
                for (index,row) in history.enumerated() {
                    let point = CGPoint(x:size.width*Double(index)/149,y:size.height/2-row[offset+axis]/scale*size.height*0.43)
                    if index == 0 { path.move(to:point) } else { path.addLine(to:point) }
                }
                context.stroke(path,with:.color(axisColors[axis].opacity(0.8)),lineWidth:1.2)
            }
        }.background(appBackground.opacity(0.4),in:RoundedRectangle(cornerRadius:8))
        .accessibilityLabel("三个原始通道的最近波形，自动缩放")
    }
}

struct PoseView: View {
    let angles:[Double]; let tint:Color
    var body: some View {
        Canvas { context,size in
            let cx = size.width/2, cy = size.height/2
            context.stroke(Path(ellipseIn:CGRect(x:cx-80,y:cy+35,width:160,height:24)),with:.color(tint.opacity(0.12)),lineWidth:1)
            let x = angles[0] * .pi/180, y = angles[1] * .pi/180, z = angles[2] * .pi/180
            func transform(_ p:[Double]) -> [Double] {
                let a = [p[0],p[1]*cos(x)-p[2]*sin(x),p[1]*sin(x)+p[2]*cos(x)]
                let b = [a[0]*cos(y)+a[2]*sin(y),a[1],-a[0]*sin(y)+a[2]*cos(y)]
                return [b[0]*cos(z)-b[1]*sin(z),b[0]*sin(z)+b[1]*cos(z),b[2]]
            }
            func project(_ p:[Double]) -> CGPoint {
                let q = transform(p); return CGPoint(x:cx+q[0]+q[2]*0.4,y:cy-q[1]+q[2]*0.28)
            }
            let vertices = [[-22.0,-54.0,-10.0],[22,-54,-10],[22,54,-10],[-22,54,-10],[-22,-54,10],[22,-54,10],[22,54,10],[-22,54,10]]
            let faces = [[0,1,2,3],[4,5,6,7],[0,1,5,4],[2,3,7,6],[0,3,7,4],[1,2,6,5]]
            for face in faces.sorted(by:{ a,b in a.map{transform(vertices[$0])[2]}.reduce(0,+) < b.map{transform(vertices[$0])[2]}.reduce(0,+) }) {
                var path = Path(); path.addLines(face.map { project(vertices[$0]) }); path.closeSubpath()
                context.fill(path,with:.color(tint.opacity(face == [4,5,6,7] ? 0.75 : 0.28)))
                context.stroke(path,with:.color(tint.opacity(0.85)),lineWidth:1)
            }
            for i in 0..<3 {
                var endpoint = [0.0,0,0]; endpoint[i] = 78
                var line = Path(); line.move(to:project([0,0,0])); line.addLine(to:project(endpoint))
                context.stroke(line,with:.color(axisColors[i]),lineWidth:2)
                context.draw(Text(["X","Y","Z"][i]).font(.system(size:10,weight:.bold)).foregroundColor(axisColors[i]),at:project(endpoint))
            }
        }.accessibilityLabel("手柄姿态演示")
    }
}

struct CalibrationView: View {
    @ObservedObject var state: ControllerState
    @ViewState private var showReset = false
    @ViewState private var face = 0
    private let permutations = [[0,1,2],[0,2,1],[1,0,2],[1,2,0],[2,0,1],[2,1,0]]
    var body: some View {
        VStack(alignment:.leading,spacing:20) {
            HStack {
                VStack(alignment:.leading,spacing:5) { Text("校准\(state.hand.title)").font(.system(size:23,weight:.semibold)); Text("先静置，再翻面，最后为三个转轴各做一次已知角度旋转。").foregroundStyle(.secondary) }
                Spacer(); Label(state.calibration.ready ? "可以输出 DSU" : "校准尚未完成",systemImage:state.calibration.ready ? "checkmark.seal.fill" : "circle.dashed").foregroundStyle(state.calibration.ready ? cyan : amber)
            }
            Text(state.message).font(.system(size:13,weight:.medium)).foregroundStyle(cyan).padding(14).frame(maxWidth:.infinity,alignment:.leading).background(cyan.opacity(0.07),in:RoundedRectangle(cornerRadius:12))
            if state.calibrating { HStack { if state.turning { ProgressView().controlSize(.small); Text("正在积分转角…") } else { ProgressView(value:state.progress) }; Spacer(); Button("取消") { state.cancelCalibration(); state.message = "校准已取消。" } } }
            GroupBox {
                HStack {
                    VStack(alignment:.leading,spacing:6) { Text("自动校准 · 30 秒").font(.headline); Text("缓慢随机翻转，在不同方向稍作停顿。自动估算加速度偏置与比例；角速度比例保留默认估算或已有校准。").foregroundStyle(.secondary) }
                    Spacer(); Button("恢复加速度默认值") { state.defaultAcceleration() }.disabled(state.calibrating)
                    Button("开始自动校准") { state.begin(.automatic) }.disabled(state.calibrating)
                }.padding(10)
            }
            GroupBox {
                HStack { VStack(alignment:.leading,spacing:6) { Text("1 · 静置校准").font(.headline); Text("将手柄放在固定表面，保持不动。采集 3 秒，估计陀螺仪零偏。").foregroundStyle(.secondary) }; Spacer(); Button(state.calibration.zeroed ? "重新采集" : "静置采集") { state.begin(.zero) }.disabled(state.calibrating); badge(state.calibration.zeroed) }.padding(10)
            }
            GroupBox {
                VStack(alignment:.leading,spacing:14) {
                    HStack { Text("2 · 加速度六面校准").font(.headline); Spacer(); badge(state.calibration.facesDone) }
                    Text("缓慢翻转手柄，让选定原始 A 轴的数值为正 / 负且幅值最大（另外两轴接近 0），保持静止后采集。每个朝向都要完成一次。").foregroundStyle(.secondary)
                    HStack(spacing:8) {
                        ForEach(0..<6,id:\.self) { i in Button {
                            face = i
                        } label: { Text("\(["X","Y","Z"][i/2])\(i%2 == 0 ? "+" : "−") \(state.faces[i] != nil ? "✓" : "")").foregroundStyle(face == i ? cyan : Color.primary).frame(maxWidth:.infinity) }.buttonStyle(.bordered) }
                    }.disabled(state.calibrating)
                    HStack {
                        ForEach(0..<3,id:\.self) { i in Text("A\(["X","Y","Z"][i]) \(Int(state.raw[i]))").font(.system(.body,design:.monospaced)).foregroundStyle(axisColors[i]) }
                        Spacer(); Button("采集 \(["X","Y","Z"][face/2])\(face%2 == 0 ? "+" : "−") · 3 秒") { state.begin(.face(face)) }.disabled(state.calibrating)
                    }
                }.padding(10)
            }
            GroupBox {
                VStack(alignment:.leading,spacing:14) {
                    HStack { Text("3 · 陀螺仪转角校准").font(.headline); Spacer(); ForEach(0..<3,id:\.self) { i in Text("G\(["X","Y","Z"][i]) \(state.calibration.gyroDone[i] ? "✓" : "○")").foregroundStyle(state.calibration.gyroDone[i] ? cyan : .secondary) } }
                    Text("选择要校准的原始 G 轴，点开始后，围绕该轴单方向转动指定角度（可借助桌边或直角参考），停稳后结束。切勿转回起点；如果其他轴变化更大，请换轴重试。分别完成 GX、GY、GZ。").foregroundStyle(.secondary)
                    HStack {
                        Picker("原始轴",selection:$state.turnAxis) { ForEach(0..<3,id:\.self) { Text("G\(["X","Y","Z"][$0])").tag($0) } }.frame(width:150).disabled(state.calibrating)
                        Picker("角度",selection:$state.turnDegrees) { Text("90°").tag(90.0); Text("180°").tag(180.0) }.frame(width:150).disabled(state.calibrating)
                        Spacer()
                        Button("开始转角") { state.begin(.turn(state.turnAxis,state.turnDegrees)) }.disabled(state.calibrating || !state.calibration.zeroed)
                        Button("结束转角") { state.finishTurn() }.disabled(!state.turning)
                    }
                    HStack { ForEach(0..<3,id:\.self) { i in Text("G\(["X","Y","Z"][i]) \(Int(state.raw[i+3]))").font(.system(.body,design:.monospaced)).foregroundStyle(axisColors[i]); Spacer() } }
                }.padding(10)
            }
            GroupBox {
                VStack(alignment:.leading,spacing:12) {
                    Text("输出坐标映射").font(.headline)
                    Text("输出 X 为俯仰轴，Y 为横滚轴，Z 为偏航轴。按实际握持方式调整，Z 符号会随右手坐标系自动计算。").foregroundStyle(.secondary)
                    HStack {
                        Picker("输出 XYZ 对应原始",selection:Binding(get:{ permutations.firstIndex(of:state.calibration.mapping) ?? 0 },set:{ state.calibration.mapping = permutations[$0]; fixSigns() })) {
                            ForEach(0..<6,id:\.self) { i in Text(permutations[i].map{["X","Y","Z"][$0]}.joined(separator:" · ")).tag(i) }
                        }.frame(width:300)
                        Toggle("反向 X",isOn:Binding(get:{ state.calibration.signs[0] < 0 },set:{ state.calibration.signs[0] = $0 ? -1 : 1; fixSigns() }))
                        Toggle("反向 Y",isOn:Binding(get:{ state.calibration.signs[1] < 0 },set:{ state.calibration.signs[1] = $0 ? -1 : 1; fixSigns() }))
                    }.disabled(state.calibrating)
                    HStack {
                        Text("A 比例：\(state.calibration.accelScale.map{String(format:"%.1f",$0)}.joined(separator:" / ")) count/g").font(.system(size:10,design:.monospaced))
                        Spacer(); Text("G 比例：\(state.calibration.gyroScale.map{String(format:"%.2f",$0)}.joined(separator:" / ")) count/(°/s)").font(.system(size:10,design:.monospaced))
                    }.foregroundStyle(.secondary)
                }.padding(10)
            }
            HStack { Text("校准会自动保存到此 Mac，重新连接后仍有效。").foregroundStyle(.secondary); Spacer(); Button("重置此手柄的校准",role:.destructive) { showReset = true } }
        }.padding(22).background(panel,in:RoundedRectangle(cornerRadius:20))
        .confirmationDialog("重置\(state.hand.title)的校准？",isPresented:$showReset) { Button("重置",role:.destructive) { state.resetCalibration() } }
    }
    func badge(_ done:Bool) -> some View { Image(systemName:done ? "checkmark.circle.fill" : "circle").foregroundStyle(done ? cyan : .secondary) }
    func fixSigns() {
        let p = state.calibration.mapping
        let inversions = (p[0] > p[1] ? 1 : 0)+(p[0] > p[2] ? 1 : 0)+(p[1] > p[2] ? 1 : 0)
        state.calibration.signs[2] = (inversions%2 == 0 ? 1 : -1)*state.calibration.signs[0]*state.calibration.signs[1]
        state.saveCalibration(); state.recenter()
    }
}

struct OutputView: View {
    @ObservedObject var output: MotionOutput
    let controllers:[ControllerState]
    var body: some View {
        VStack(alignment:.leading,spacing:24) {
            Text("把动作交给其他程序").font(.system(size:25,weight:.semibold))
            Text("标准 DSU 提供体感数据；JSON 便于接入自己的程序。两路输出都只在这台 Mac 上运行。").foregroundStyle(.secondary)
            GroupBox {
                VStack(alignment:.leading,spacing:16) {
                    HStack { Label("DSU / Cemuhook",systemImage:"gamecontroller").font(.title2); Spacer(); Toggle("开启 DSU",isOn:Binding(get:{ output.dsuEnabled },set:{ output.setDSU($0) })).toggleStyle(.switch) }
                    Text("127.0.0.1 : 26760").font(.system(size:25,weight:.medium,design:.monospaced)).foregroundStyle(cyan)
                    Toggle("Joy-Con Pair · 键盘按键",isOn:Binding(get:{ output.pairMode },set:{ output.setPairMode($0) }))
                    if output.pairMode {
                        Picker("输出槽位",selection:$output.pairHand) { Text("槽位 0").tag(0); Text("槽位 1").tag(1) }
                        Toggle("双手混合到同一个槽位",isOn:$output.mixHands)
                        HStack { Text(output.keyboardPermission ? "输入监控：已授权" : "输入监控：未授权，请在系统设置中允许 WeeWaa Motion"); if !output.keyboardPermission { SettingsLink(title:"打开输入监控设置",anchor:"Privacy_ListenEvent") }; Spacer(); Text("当前按键：\(output.pressedKeys)") }.font(.system(size:12)).foregroundStyle(output.keyboardPermission ? cyan : amber)
                        Text("方向键：十字键  ·  A/S/Z/X：A/X/B/Y  ·  Q/E：L/R  ·  W/D：ZL/ZR  ·  F/R：L3/R3  ·  回车：+  ·  删除：−  ·  空格：Home").font(.system(size:12)).textSelection(.enabled)
                        Text(output.mixHands ? "左右手的数据交替发送到所选槽位，模拟器会把它们当作同一个传感器，动作可能互相干扰。键盘可独立于手柄连接使用；摇杆保持中立。" : "槽位 0 对应左手，槽位 1 对应右手。键盘可独立于手柄连接使用；摇杆保持中立。") .foregroundStyle(amber)
                    } else {
                        Text("槽位 0 是左手，槽位 1 是右手；按键和摇杆保持中立。") .foregroundStyle(.secondary)
                    }
                    ForEach(controllers) { DSUStateRow(state:$0) }
                    HStack { Text(output.status); Spacer(); Text("\(output.clientCount) 个订阅客户端 · 已发送 \(output.sent) 包") }.font(.system(size:11,design:.monospaced)).foregroundStyle(.secondary)
                    Link("DSU 协议参考",destination:URL(string:"https://v1993.github.io/cemuhook-protocol/")!).font(.system(size:11))
                }.padding(14)
            }
            GroupBox {
                VStack(alignment:.leading,spacing:14) {
                    HStack { Label("鼠标模式",systemImage:"cursorarrow.motionlines").font(.title2); Spacer(); Toggle("开启鼠标模式",isOn:Binding(get:{ output.mouseEnabled },set:{ output.setMouseMode($0) })).toggleStyle(.switch) }
                    Picker("移动指针的手柄",selection:$output.mouseHand) { Text("左手柄移动，右手柄敲击点击").tag(0); Text("右手柄移动，左手柄敲击点击").tag(1) }
                    HStack { Text("移动灵敏度"); Slider(value:$output.mouseSensitivity,in:2...20); Text(String(format:"%.1f",output.mouseSensitivity)).frame(width:36) }
                    HStack { Text("敲击阈值"); Slider(value:$output.tapThreshold,in:0.5...3); Text(String(format:"%.1f g",output.tapThreshold)).frame(width:48) }
                    HStack { Toggle("水平反向",isOn:$output.invertMouseX); Toggle("垂直反向",isOn:$output.invertMouseY) }
                    Text("转动移动手柄控制指针；短促敲击另一只手柄触发鼠标左键。数值越高，敲击需要越用力。建议先完成静置校准。") .foregroundStyle(.secondary)
                    HStack {
                        Text(output.mousePermission ? "辅助功能：已授权" : "辅助功能：未授权，请在系统设置中允许 WeeWaa Motion。")
                        if !output.mousePermission { SettingsLink(title:"打开辅助功能设置",anchor:"Privacy_Accessibility") }
                    }.font(.system(size:12)).foregroundStyle(output.mousePermission ? cyan : amber)
                }.padding(14)
            }
            GroupBox {
                VStack(alignment:.leading,spacing:16) {
                    HStack { Label("实时 JSON",systemImage:"curlybraces").font(.title2); Spacer(); Toggle("开启 JSON",isOn:$output.jsonEnabled).toggleStyle(.switch) }
                    Text("127.0.0.1 : 8765").font(.system(size:25,weight:.medium,design:.monospaced)).foregroundStyle(amber)
                    Text("每个有效样本发送一个 UDP JSON 对象，含 hand、timestamp_us、raw_axes、accel_g、gyro_dps、calibrated。未完成校准时 calibrated 为 false，物理量为估算；演示数据不发送。").foregroundStyle(.secondary)
                    Text("{\"hand\":\"left\", \"raw_axes\":[…], \"accel_g\":[…], \"gyro_dps\":[…], \"calibrated\":true}").font(.system(size:11,design:.monospaced)).textSelection(.enabled)
                }.padding(14)
            }
            GroupBox {
                VStack(alignment:.leading,spacing:14) {
                    HStack { Label("游戏震动回传",systemImage:"waveform").font(.title2); Spacer(); Toggle("接收游戏震动",isOn:Binding(get:{ output.rumbleEnabled },set:{ output.setRumble($0) })).toggleStyle(.switch) }
                    Text("127.0.0.1 : 8766").font(.system(size:25,weight:.medium,design:.monospaced)).foregroundStyle(cyan)
                    Text("供 nxnative 接入补丁或自己的程序回传震动。当前映射为原厂固定短脉冲，最多每手每秒 4 次；不等同于 Switch HD Rumble，也未实现精确强度与频率控制。强度 0 不触发新脉冲，已经触发的短脉冲会自行结束。").foregroundStyle(.secondary)
                    Text("{\"type\":\"rumble\",\"hand\":\"left\",\"intensity\":1.0}").font(.system(size:11,design:.monospaced)).textSelection(.enabled)
                    Text(output.rumbleStatus).font(.system(size:11)).foregroundStyle(.secondary)
                }.padding(14)
            }
            Label("未完整校准时使用默认估算值输出。校准、断连或数据中断时暂停该手柄输出。",systemImage:"checkmark.seal").font(.system(size:12)).foregroundStyle(.secondary)
        }.padding(24).background(panel,in:RoundedRectangle(cornerRadius:20))
    }
}
struct DSUStateRow: View {
    @ObservedObject var state:ControllerState
    var body: some View {
        HStack { Text("槽位 \(state.hand.rawValue) · \(state.hand.title)"); Spacer(); Text(state.streaming && !state.demo ? (state.calibration.ready ? "已校准 · 可以输出" : "默认估算 · 可以输出") : "等待真实手柄数据").foregroundStyle(state.calibration.ready ? cyan : amber) }.font(.system(size:12))
    }
}
