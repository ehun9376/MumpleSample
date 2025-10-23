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
        MKVersion.shared().setOpusEnabled(true)
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
        
        let localP12: Data? = self.loadP12FromKeychain(userName: self.username)

        // ⬇️ 在 connect() 之前，設定真正的 client certificate
        if let clientCert = MKCertificate.selfSignedCertificate(withName: username, email: nil),
           let sslArray = self.makeClientSSLArray(localData: localP12, from: clientCert, password: username, userName: username) {
            conn?.setCertificateChain(sslArray)
            print("✅ TLS client certificate chain applied.")
        } else {
            print("⚠️ Failed to generate SecIdentity for client certificate")
        }

        print("Connecting to \(host):\(port)...")
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
    
    func createChannel(name: String, maxUsers: Int = 2, parent: MKChannel? = nil) {
        
        guard let model = serverModel else { return }

        model.createChannel(withName: name, parent: parent, temporary: true)
        
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
    
    func serverModel(_ model: MKServerModel!, permissionDeniedForReason reason: String!) {
        print("permissionDeniedForReason: \(reason ?? "")")
    }
    
    func serverModel(_ model: MKServerModel!, permissionDenied perm: MKPermission, for user: MKUser!, in channel: MKChannel!) {
        print("permissionDenied: perm=\(perm.rawValue) user=\(user.userName() ?? "") channel=\(channel.channelName() ?? "")")
    }
    
    
    func serverModel(_ model: MKServerModel!, channelRemoved channel: MKChannel!) {
        DispatchQueue.main.async { [weak self] in
            self?.onModelChanged?()
        }
    }
    
    func serverModel(_ model: MKServerModel!, channelAdded channel: MKChannel!) {
        DispatchQueue.main.async { [weak self] in
            self?.onModelChanged?()
        }
    }

    func serverModel(_ model: MKServerModel!, joinedServerAs user: MKUser!, withWelcome msg: MKTextMessage!) {
        print("✅ joinedServerAsUser: \(user.userName() ?? "")")

        // 判斷是否為臨時用戶（userId == 0 表示未註冊）
        if user.userId() == 0 {
            print("🆕 Temporary user detected — registering...")
            model.registerConnectedUser()
        } else {
            print("🔐 Already registered user (\(user.userId())) — skip registration")
        }

        // 啟動音訊
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
    
    func serverModel(_ model: MKServerModel!, missingCertificateErrorFor user: MKUser!) {
        print("missingCertificateErrorFor user: \(user.userName() ?? "")")
    }
    
    
}

extension MumbleConnector {
    func makeClientSSLArray(localData: Data? = nil, from mkCert: MKCertificate, password: String, userName: String) -> [Any]? {
        guard let p12Data = localData ?? mkCert.exportPKCS12(withPassword: password) else {
            print("❌ exportPKCS12 failed")
            return nil
        }

        var items: CFArray?
        let options: [String: Any] = [kSecImportExportPassphrase as String: password]
        let status = SecPKCS12Import(p12Data as CFData, options as CFDictionary, &items)

        guard status == errSecSuccess,
              let imported = items as? [[String: Any]],
              let first = imported.first,
              let identityAny = first[kSecImportItemIdentity as String] else {
            print("❌ SecPKCS12Import failed (\(status))")
            return nil
        }

        let identity = identityAny as! SecIdentity

        // 取出完整鏈
        let certs = first[kSecImportItemCertChain as String] as? [SecCertificate] ?? []

        // SSL 要求格式：[SecIdentity, SecCertificate...]
        var sslArray: [Any] = [identity]
        sslArray.append(contentsOf: certs)
        
        self.storeP12InKeychain(p12Data: p12Data, password: password, userName: userName)

        return sslArray
    }
    
    func storeP12InKeychain(p12Data: Data, password: String, userName: String) {
        // 1️⃣ 找到 Documents 目錄
        guard let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let fileURL = documentsURL.appendingPathComponent("\(userName).p12")

        do {
            // 2️⃣ 寫入 .p12
            try p12Data.write(to: fileURL, options: .atomic)
            print("💾 p12 憑證已儲存成功：\(fileURL.path)")

            // 3️⃣ 驗證是否可讀
            if let readData = try? Data(contentsOf: fileURL) {
                print("📦 讀取成功，大小：\(readData.count) bytes")
            } else {
                print("⚠️ 無法讀取剛剛寫入的 p12")
            }
        } catch {
            print("❌ 儲存 p12 憑證失敗：\(error)")
        }
    }

    
    func loadP12FromKeychain(userName: String) -> Data?  {
        guard let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        let fileURL = documentsURL.appendingPathComponent("\(userName).p12")

        if let p12Data = try? Data(contentsOf: fileURL) {
            return p12Data
        } else {
            return nil
        }
    }

}
