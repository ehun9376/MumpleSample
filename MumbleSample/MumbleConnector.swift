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

protocol ConnectorProtocol {
    var connection: MKConnection? { get set }
    var serverModel: MKServerModel? { get set }
    var rootChannel: MKChannel? { get }
    /// 有新增移除頻道、使用者加入、使用者移動頻道等事件時觸發
    var onModelChanged: (() -> ())? { get set }
    /// 使用者講話狀態改變時觸發
    var onUserTalkStateChanged: ((MKUser, Bool) -> ())? { get set }
    /// 連線狀態改變時觸發
    var onConnectionStateChange: ((ConnectionState) -> Void)? { get set }
    ///啟動連線
    func start()
    /// 停止連線
    func stop()
    /// 靜音/取消靜音
    func setMuted(_ muted: Bool)
    /// 自我靜音/取消自我靜音
    func setSelfDeafened(_ deaf: Bool)
    /// 切換頻道
    func join(channel: MKChannel)
    

}


class MumbleConnector: NSObject, ConnectorProtocol {
    
    static let shared = MumbleConnector()

    var connection: MKConnection?
    
    var serverModel: MKServerModel?

    // MARK: - Connection Info
    private var host: String = "uat-voip.1111job.app"
    private var port: UInt = 64738
    private var username: String = UUID().uuidString.prefix(8).description
    private var password: String = "52@11118888"
    private var targetChannelID: String?


    // MARK: - State
    private(set) var isMuted: Bool = false
    private(set) var isSelfDeafened: Bool = false

    /// 有新增移除頻道、使用者加入、使用者移動頻道等事件時觸發
    var onModelChanged: (() -> ())?
    
    /// 使用者講話狀態改變時觸發
    var onUserTalkStateChanged: ((MKUser, Bool) -> ())?
    
    /// 連線狀態改變時觸發
    var onConnectionStateChange: ((ConnectionState) -> Void)?

    var rootChannel: MKChannel? { serverModel?.rootChannel() }

    // MARK: - Init
    
    func startCall(targetChannelID: String) {
        self.targetChannelID = targetChannelID
        self.start()
    }


    // MARK: - Public Controls
    func start() {
        MKVersion.shared().setOpusEnabled(true)
        let conn = MKConnection()
        self.connection = conn
        conn?.setDelegate(self)



        let model = MKServerModel(connection: conn)
        self.serverModel = model
        model?.addDelegate(self)
        conn?.setMessageHandler(model)
        

        if let clientCert = MKCertificate.selfSignedCertificate(withName: username, email: nil),
           let sslArray = self.makeClientSSLArray(localData: self.loadP12FromKeychain(userName: self.username),
                                                  from: clientCert,
                                                  password: username,
                                                  userName: username) {
            conn?.setCertificateChain(sslArray)
            
        }

        conn?.connect(toHost: host, port: self.port)
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
        // 啟動音訊
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            let session = AVAudioSession.sharedInstance()
            
            do {
                try session.setCategory(.playAndRecord,
                                        options: [.defaultToSpeaker, .allowBluetoothHFP, .mixWithOthers])
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
            
            if !MKAudio.shared().isRunning() {
                MKAudio.shared().start()
            }
            
            if let conn = connection {
                MKAudio.shared().setMainConnectionFor(conn)
            }
            
            
            self.onConnectionStateChange?(.connected)
            self.onModelChanged?()
            self.joinChannelByIDIfNeed()
        }
        
    }
    
    func joinChannelByIDIfNeed() {
        guard let model = self.serverModel,
              let channelID = self.targetChannelID,
              !channelID.isEmpty,
              let channel = model.channel(withId: UInt(channelID) ?? 0) else { return }
        self.join(channel: channel)
    }

        
    
    func createChannel(name: String, parent: MKChannel? = nil) {
        
        guard let model = self.serverModel else { return }

        model.createChannel(withName: name, parent: parent, temporary: true)
        
    }
    
    

}

// MARK: - MKConnectionDelegate
extension MumbleConnector: MKConnectionDelegate {

    func connectionOpened(_ conn: MKConnection!) {
        print("connectionOpened")

        conn?.authenticate(withUsername: username,
                           password: password,
                           accessTokens: nil)

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
        self.onModelChanged?()
    }
    
    func serverModel(_ model: MKServerModel!, channelAdded channel: MKChannel!) {
        self.onModelChanged?()
    }

    func serverModel(_ model: MKServerModel!, joinedServerAs user: MKUser!, withWelcome msg: MKTextMessage!) {

        if user.userId() == 0 {
            model.registerConnectedUser()
        }
  
        self.startAudioAfterServerSync()
        
    }

    
    func serverModel(_ model: MKServerModel!, userLeft user: MKUser!) {
        self.onModelChanged?()
    }
    

    func serverModelDisconnected(_ model: MKServerModel!) {
        onConnectionStateChange?(.disconnected)
    }
    
    func serverModel(_ model: MKServerModel!, userMoved user: MKUser!, to chan: MKChannel!, from prevChan: MKChannel!, by mover: MKUser!) {
        self.onModelChanged?()
    }
    
    func serverModel(_ model: MKServerModel!, userTalkStateChanged user: MKUser!) {
        let isTalking = user.talkState() == MKTalkState(rawValue: 1)
        self.onUserTalkStateChanged?(user, isTalking)
        
    }
    
    func serverModel(_ model: MKServerModel!, missingCertificateErrorFor user: MKUser!) {
        print("missingCertificateErrorFor user: \(user.userName() ?? "")")
    }
    
    
}

