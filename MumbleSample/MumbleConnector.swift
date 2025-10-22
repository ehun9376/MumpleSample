//
//  MumbleConnector.swift
//  MumbleSample
//
//  Created by 陳逸煌 on 2025/10/21.
//

import AVFAudio

enum ConnectionState {
    case connected
    case disconnected
}

final class MumbleConnector: NSObject {

    private var connection: MKConnection?
    var serverModel: MKServerModel?

    // MARK: - Connection Info
    private let host: String
    private let port: UInt
    private let username: String
    private let password: String?
    private let accessTokens: [String]?
    private let allowSelfSigned: Bool
    private let forceTCP: Bool

    // MARK: - State
    var onConnectionStateChange: ((ConnectionState) -> Void)?
    private(set) var isMuted: Bool = false
    private(set) var isSelfDeafened: Bool = false

    // 提供 UI 使用的模型入口與更新通知
    var onModelChanged: (() -> ())?
    var rootChannel: MKChannel? { serverModel?.rootChannel() }
    var connectedUser: MKUser? { serverModel?.connectedUser() }
    var onUserTalkStateChanged: ((MKUser, Bool) -> Void)?


    // MARK: - Init
    init(host: String,
         port: UInt = 64738,
         username: String,
         password: String? = nil,
         accessTokens: [String]? = nil,
         allowSelfSigned: Bool = false,
         forceTCP: Bool = false) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.accessTokens = accessTokens
        self.allowSelfSigned = allowSelfSigned
        self.forceTCP = forceTCP
        super.init()
    }

    // MARK: - Public Controls
    func start() {
        // 啟用 Opus 支援
        MKVersion.shared().setOpusEnabled(true)

        // 建立連線
        let conn = MKConnection()
        self.connection = conn
        conn?.setDelegate(self)

        if allowSelfSigned {
            conn?.setIgnoreSSLVerification(true)
        }
        if forceTCP {
            conn?.setForceTCP(true)
        }

        let model = MKServerModel(connection: conn)
        self.serverModel = model
        model?.addDelegate(self)
        conn?.setMessageHandler(model)

        print("Connecting to \(host):\(port) ...")
        conn?.connect(toHost: host, port: UInt(Int(port)))
    }

    func stop() {
        if MKAudio.shared().isRunning() {
            MKAudio.shared().stop()
        }
        connection?.disconnect()
        connection = nil
        serverModel = nil
        onConnectionStateChange?(.disconnected)
    }

    func setMuted(_ muted: Bool) {
        isMuted = muted
        serverModel?.setSelfMuted(muted, andSelfDeafened: isSelfDeafened)
        MKAudio.shared().setSelfMuted(muted)
    }

    func setSelfDeafened(_ deaf: Bool) {
        isSelfDeafened = deaf
        serverModel?.setSelfMuted(isMuted, andSelfDeafened: deaf)
    }

    // 切換頻道
    func join(channel: MKChannel) {
        serverModel?.join(channel)
    }

    // MARK: - Audio Setup
    private func startAudioAfterServerSync() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord,
                                    options: [.defaultToSpeaker, .allowBluetooth, .mixWithOthers])
            try session.setPreferredSampleRate(48000)
            try session.setActive(true)
            print("✅ AVAudioSession active, inputAvailable:", session.isInputAvailable)
        } catch {
            print("❌ AVAudioSession setup failed:", error)
        }

        let route = session.currentRoute
        for input in route.inputs {
            print("🎙 Input port:", input.portName, input.portType.rawValue)
        }
        for output in route.outputs {
            print("🔈 Output port:", output.portName, output.portType.rawValue)
        }

        // 音訊參數設定
        var settings = MKAudioSettings()
        MKAudio.shared().read(&settings)
        settings.enableEchoCancellation = false
        settings.transmitType = MKTransmitTypeContinuous
        settings.preferReceiverOverSpeaker = false
        settings.enableSideTone = false
        MKAudio.shared().update(&settings)
        MKAudio.shared().setForceTransmit(true)

        // 啟動音訊裝置
        if !MKAudio.shared().isRunning() {
            MKAudio.shared().start()
        }

        // 綁定連線
        if let conn = connection {
            print("🔗 Binding MKConnection to MKAudioInput via selector")
            MKAudio.shared().setMainConnectionFor(conn)

            if let ai = MKAudio.shared().value(forKey: "_audioInput") as? NSObject {
                ai.perform(NSSelectorFromString("setMainConnectionForAudio:"), with: conn)
                print("🪢 Rebind connection on _audioInput directly")
            }
        }

        // 取消靜音與強制傳輸
        MKAudio.shared().setSelfMuted(false)
        MKAudio.shared().setForceTransmit(true)
        serverModel?.setSelfMuted(false, andSelfDeafened: false)

        print("🎚 speechProb=\(MKAudio.shared().speechProbablity()) peak=\(MKAudio.shared().peakCleanMic())")

        if let input = MKAudio.shared().value(forKey: "_audioInput") as? NSObject {
            input.setValue(true, forKey: "_forceTransmit")
            print("🟢 ForceTransmit flag manually set")
        }

        if let ai = MKAudio.shared().value(forKey: "_audioInput") as? NSObject,
           let conn = connection {
            ai.perform(NSSelectorFromString("setMainConnectionForAudio:"), with: conn)
            print("🪢 Rebind connection on _audioInput directly")
        }

        onConnectionStateChange?(.connected)
        // 初次同步完成後，通知 UI 可以讀取頻道/使用者
        DispatchQueue.main.async { [weak self] in
            self?.onModelChanged?()
        }
    }
}

// MARK: - MKConnectionDelegate
extension MumbleConnector: MKConnectionDelegate {

    func connectionOpened(_ conn: MKConnection!) {
        print("connectionOpened")

        conn?.authenticate(withUsername: username,
                           password: password ?? "",
                           accessTokens: accessTokens)

        let trusted = conn?.peerCertificateChainTrusted()
        print("Server certificate trusted by system root CAs? \(trusted ?? false)")
        if let certs = conn?.peerCertificates() as? [MKCertificate] {
            print("Server presented \(certs.count) certificate(s). Leaf hex SHA1: \(certs.first?.hexDigest() ?? "-")")
        }
    }

    func connection(_ conn: MKConnection!, trustFailureInCertificateChain chain: [Any]!) {
        print("trustFailureInCertificateChain. Certificates count: \(chain?.count ?? 0)")
    }

    func connection(_ conn: MKConnection!, rejectedWith reason: MKRejectReason, explanation: String!) {
        print("rejected: reason=\(reason.rawValue) explanation=\(explanation ?? "")")
        onConnectionStateChange?(.disconnected)
    }

    func connection(_ conn: MKConnection!, unableToConnectWithError err: Error!) {
        print("unableToConnectWithError: \(err.localizedDescription)")
        onConnectionStateChange?(.disconnected)
    }

    func connection(_ conn: MKConnection!, closedWithError err: Error!) {
        if let err = err {
            print("closedWithError: \(err.localizedDescription)")
        } else {
            print("closed normally")
        }
        onConnectionStateChange?(.disconnected)
    }
    
}

// MARK: - MKServerModelDelegate
extension MumbleConnector: MKServerModelDelegate {

    func serverModel(_ model: MKServerModel!, joinedServerAs user: MKUser!, withWelcome msg: MKTextMessage!) {
        print("joinedServerAsUser")

        // 延遲 1 秒啟動音訊，確保伺服器同步完畢
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.startAudioAfterServerSync()
        }
    }
    
    func serverModel(_ model: MKServerModel!, userLeft user: MKUser!) {
        DispatchQueue.main.async { [weak self] in
            self?.onModelChanged?()
        }
    }
    

    func serverModelDisconnected(_ model: MKServerModel!) {
        print("serverModelDisconnected")
        onConnectionStateChange?(.disconnected)
    }
    
    func serverModel(_ model: MKServerModel!, userMoved user: MKUser!, to chan: MKChannel!, from prevChan: MKChannel!, by mover: MKUser!) {
        DispatchQueue.main.async { [weak self] in
            self?.onModelChanged?()
        }
    }
    
    func serverModel(_ model: MKServerModel!, userTalkStateChanged user: MKUser!) {
        print("user.talkState: \(user.talkState())")
        
        let isTalking = user.talkState() == MKTalkState(rawValue: 1)
        DispatchQueue.main.async { [weak self] in
            self?.onUserTalkStateChanged?(user, isTalking)
        }
    }
}
