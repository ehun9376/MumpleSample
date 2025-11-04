//
//  MumbleConnectorImpl.swift
//  MumbleSample
//
//  Created by 陳逸煌 on 2025/10/21.
//

import AVFAudio

enum ConnectionState {
    case connected
    case disconnected
}

protocol MumbleConnector {
    var connectionDelegate: MumbleConnectionDelegate? { get set }
    
    var stateDelegate: MumbleStateDelegate? { get set }

    func startAudio()
    
    func stop()
    
    func toggleMuted() -> Bool
    
    func toggleSelfDeafened() -> Bool
    
    func startConnect(with channelID: UInt)
    
    func makeCallWithCreateAChannel(to user: String)
}

class MumbleConnectorImpl: NSObject, MumbleConnector {
    
    var connection: MKConnection?
    
    var serverModel: MKServerModel?
    
    var connectionDelegate: MumbleConnectionDelegate?
    
    var stateDelegate: MumbleStateDelegate?
        
    private var answerChannelID: UInt?

    // MARK: - State
    private(set) var isMuted: Bool = false
    private(set) var isSelfDeafened: Bool = false


    var openChannel: MKChannel? {
        return (self.serverModel?.rootChannel().channels() as? [MKChannel])?.first(where: { channel in
            return channel.channelName()?.contains("openchannel") ?? false
        })
    }
    
    var rootChannel: MKChannel? {
        return self.serverModel?.rootChannel()
    }
    
    var newChannelName: String?


    // MARK: - Public Controls



    func toggleMuted() -> Bool {
        self.isMuted.toggle()
        self.serverModel?.setSelfMuted(self.isMuted, andSelfDeafened: self.isSelfDeafened)
        MKAudio.shared().setSelfMuted(self.isMuted)
        return self.isMuted
    }

    func toggleSelfDeafened() -> Bool {
        self.isSelfDeafened.toggle()
        self.serverModel?.setSelfMuted(self.isMuted, andSelfDeafened: self.isSelfDeafened)
        return self.isSelfDeafened
    }
    
    //TODO: param新增userID
    func makeCallWithCreateAChannel(to user: String) {
        self.stop()
        let uuid = UUID().uuidString
        self.newChannelName = uuid
        print("📡 準備建立新頻道：\(uuid)")
        self.start()
    }
    
    func startConnect(with channelID: UInt) {
        self.answerChannelID = channelID
        self.start()
    }
    
    private func start() {
        
        MKVersion.shared().setOpusEnabled(true)
        let conn = MKConnection()
        self.connection = conn
        conn?.setDelegate(self)

        let model = MKServerModel(connection: conn)
        self.serverModel = model
        model?.addDelegate(self)
        conn?.setMessageHandler(model)
        
        guard let config = self.connectionDelegate?.getConfig() else {
            return
        }
        
        guard let clientCert = MKCertificate.selfSignedCertificate(withName: config.username, email: nil) else {
            return
        }
        
        self.makeClientSSLArray(localData: self.loadP12FromKeychain(userName: config.username),
                                from: clientCert,
                                password: config.username,
                                userName: config.username,
                                complete: { [weak self] sslArray in
            guard let self = self else { return }
            //要在連線建立前就設定憑證，不然會沒有效果
            conn?.setCertificateChain(sslArray)
            conn?.connect(toHost: self.connectionDelegate?.getConfig().host ?? "", port: self.connectionDelegate?.getConfig().port ?? 0)
            
        })
          
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
        serverModel = nil
        self.stateDelegate?.onConnectionStateChange(status: .disconnected)
        
        self.connectionDelegate?.setServerReady(false)

        print("🧹 Connection + state reset complete")
    }


  

    ///要在Callkit通話跟mumble都建立好後再啟動，不然會沒有效果
    func startAudio() {
 
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
    
    // 切換頻道
    private func join(channel: MKChannel) {
        self.serverModel?.join(channel)
    }
    
    
    private func joinChannelByIDIfNeed() {
        guard let model = self.serverModel,
              let channelID = self.answerChannelID,
              let channel = model.channel(withId: channelID) else { return }
        self.join(channel: channel)
    }


    
    private func createAndJoinChannelIfNeed(to user: String) {
        
        guard let model = self.serverModel else { return }
        guard let channelName = self.newChannelName else { return }
        print("🧱 嘗試建立頻道：\(channelName)")
        model.createChannel(withName: channelName, parent: self.openChannel, temporary: true)
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self = self else { return }
            guard let channel = self.findChannelByName(channel: self.openChannel, channelName: channelName) else { return }
            self.join(channel: channel)
            self.connectionDelegate?.startCallKitOutgoing(to: user, channelID: channel.channelId())
        }
    }
    
    private func findChannelByName(channel: MKChannel?, channelName: String) -> MKChannel? {
        
        let targetChannel: MKChannel? = channel ?? self.rootChannel
        guard let channels = targetChannel?.channels() as? [MKChannel] else {
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
extension MumbleConnectorImpl: MKConnectionDelegate {

    func connectionOpened(_ conn: MKConnection!) {
        print("connectionOpened")

        conn?.authenticate(withUsername: self.connectionDelegate?.getConfig().username,
                           password: self.connectionDelegate?.getConfig().serverPassword,
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
        self.stateDelegate?.onConnectionStateChange(status: .disconnected)
    }

    func connection(_ conn: MKConnection!, unableToConnectWithError err: Error!) {
        print("unableToConnectWithError: \(err.localizedDescription)")
        self.connectionDelegate?.endConnected()
        self.stateDelegate?.onConnectionStateChange(status: .disconnected)
    }

    func connection(_ conn: MKConnection!, closedWithError err: Error!) {
        if let err = err {
            print("closedWithError: \(err.localizedDescription)")
        } else {
            print("closed normally")
        }
        self.connectionDelegate?.endConnected()
        self.stateDelegate?.onConnectionStateChange(status: .disconnected)
    }

}


// MARK: - MKServerModelDelegate
extension MumbleConnectorImpl: MKServerModelDelegate {
    
    func serverModel(_ model: MKServerModel!, permissionDeniedForReason reason: String!) {
        print("permissionDeniedForReason: \(reason ?? "")")
    }
    
    func serverModel(_ model: MKServerModel!, permissionDenied perm: MKPermission, for user: MKUser!, in channel: MKChannel!) {
        print("permissionDenied: perm=\(perm.rawValue) user=\(user.userName() ?? "") channel=\(channel.channelName() ?? "")")
    }
    
    
    func serverModel(_ model: MKServerModel!, channelRemoved channel: MKChannel!) {
        self.stateDelegate?.onModelChanged(model: model)
    }
    
    func serverModel(_ model: MKServerModel!, channelAdded channel: MKChannel!) {
        self.stateDelegate?.onModelChanged(model: model)
    }

    func serverModel(_ model: MKServerModel!, joinedServerAs user: MKUser!, withWelcome msg: MKTextMessage!) {

        self.connectionDelegate?.setServerReady(true)
        
        self.stateDelegate?.onConnectionStateChange(status: .connected)
        self.stateDelegate?.onModelChanged(model: model)
        
        self.joinChannelByIDIfNeed()
        self.createAndJoinChannelIfNeed(to: "TODO: User Name")
        if user.userId() == 0 {
            model.registerConnectedUser()
        }
        
    }

    
    func serverModel(_ model: MKServerModel!, userLeft user: MKUser!) {
        self.stateDelegate?.onModelChanged(model: model)
    }
    

    func serverModelDisconnected(_ model: MKServerModel!) {
        self.stateDelegate?.onConnectionStateChange(status: .disconnected)
    }
    
    func serverModel(_ model: MKServerModel!, userMoved user: MKUser!, to chan: MKChannel!, from prevChan: MKChannel!, by mover: MKUser!) {
        self.stateDelegate?.onModelChanged(model: model)
    }
    
    func serverModel(_ model: MKServerModel!, userTalkStateChanged user: MKUser!) {
        let isTalking = user.talkState() == MKTalkState(rawValue: 1)
        self.stateDelegate?.onUserTalkStateChanged(user: user, isTalking: isTalking)
        
    }
    
    func serverModel(_ model: MKServerModel!, missingCertificateErrorFor user: MKUser!) {
        print("missingCertificateErrorFor user: \(user.userName() ?? "")")
    }
    
    
}

