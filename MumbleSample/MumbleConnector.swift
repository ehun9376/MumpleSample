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
    var openChannel: MKChannel? { get }
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
    private var targetChannelID: UInt?


    // MARK: - State
    private(set) var isMuted: Bool = false
    private(set) var isSelfDeafened: Bool = false

    /// 有新增移除頻道、使用者加入、使用者移動頻道等事件時觸發
    var onModelChanged: (() -> ())?
    
    /// 使用者講話狀態改變時觸發
    var onUserTalkStateChanged: ((MKUser, Bool) -> ())?
    
    /// 連線狀態改變時觸發
    var onConnectionStateChange: ((ConnectionState) -> Void)?

    var openChannel: MKChannel? {
      return (serverModel?.rootChannel().channels() as? [MKChannel])?.first(where: { channel in
            return channel.channelName()?.contains("openchannel") ?? false
          
        })
    }
    
    var rootChannel: MKChannel? {
        return serverModel?.rootChannel()
    }
    
    var newChannelName: String?
    
    var serverReady: Bool = false {
        didSet {
            self.startAudioAfterServerSync()
        }
    }
    
    var callKitReady: Bool = false {
        didSet {
            self.startAudioAfterServerSync()
        }
    }
        


    
    func connectCall(answerChannelID: UInt) {
        self.targetChannelID = answerChannelID
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
        print("🛑 Stopping Mumble connection...")

        if MKAudio.shared().isRunning() {
            MKAudio.shared().stop()
            print("🔇 MKAudio stopped")
        }

        var settings = MKAudioSettings()
        MKAudio.shared().read(&settings)
        MKAudio.shared().update(&settings)

 

        connection?.disconnect()
        connection = nil
        self.onConnectionStateChange?(.disconnected)
        serverModel = nil
        callKitReady = false
        serverReady = false
        print("🧹 Connection + state reset complete")
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
    func startAudioAfterServerSync() {
        guard self.serverReady, self.callKitReady else {
            print("⏳ 等待 Server 與 CallKit 準備完成...")
            return
        }
        // 啟動音訊
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            // 音訊參數設定
            var settings = MKAudioSettings()
            MKAudio.shared().read(&settings)
            settings.enableEchoCancellation = false
            settings.transmitType = MKTransmitTypeContinuous
            settings.enableSideTone = true
            MKAudio.shared().update(&settings)
            MKAudio.shared().setForceTransmit(true)
            
            if !MKAudio.shared().isRunning() {
                MKAudio.shared().start()
            }
            
            if let conn = connection {
                MKAudio.shared().setMainConnectionFor(conn)
            }
   
        }
        
    }
    
    func joinChannelByIDIfNeed() {
        guard let model = self.serverModel,
              let channelID = self.targetChannelID,
              let channel = model.channel(withId: channelID) else { return }
        self.join(channel: channel)
    }

    
    func makeCallWithCreateAChannel(to user: String) {
        MumbleConnector.shared.stop()
        let uuid = UUID().uuidString
        self.newChannelName = uuid
        print("📡 準備建立新頻道：\(uuid)")
        self.start()
    }
    
    private func makeCall(channelID: UInt) {
        CallKitManager.shared.startOutgoing(to: "Other", channelID: channelID)
    }
    
    private func createAndJoinChannelIfNeed() {
        
        guard let model = self.serverModel else { return }
        guard let channelName = self.newChannelName else { return }
        print("🧱 嘗試建立頻道：\(channelName)")
        model.createChannel(withName: channelName, parent: self.openChannel, temporary: true)
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self = self else { return }
            guard let channel = self.findChannelByName(channel: self.openChannel, channelName: channelName) else { return }
            self.join(channel: channel)
            self.makeCall(channelID: channel.channelId())
        }
    }
    
    private func findChannelByName(channel: MKChannel?, channelName: String) -> MKChannel? {
        guard let channels = channel?.channels() as? [MKChannel] else {
            return nil
        }
        
        for channel in channels {
            if channel.channelName() == channelName {
                return channel
            }
            
            if let channels = channel.channels() as? [MKChannel],
                !channels.isEmpty,
               let found = findChannelByName(channel: channel, channelName: channelName) {
                return found
            }
        }
        return nil
        
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
        CallKitManager.shared.endCall()
        onConnectionStateChange?(.disconnected)
    }

    func connection(_ conn: MKConnection!, closedWithError err: Error!) {
        if let err = err {
            print("closedWithError: \(err.localizedDescription)")
        } else {
            print("closed normally")
        }
        CallKitManager.shared.endCall()
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

        
        self.serverReady = true
        self.onConnectionStateChange?(.connected)
        self.onModelChanged?()
        self.startAudioAfterServerSync()
        self.joinChannelByIDIfNeed()
        self.createAndJoinChannelIfNeed()
        if user.userId() == 0 {
            model.registerConnectedUser()
        }
        
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

