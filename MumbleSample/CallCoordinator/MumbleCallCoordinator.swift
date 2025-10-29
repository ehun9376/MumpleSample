//
//  MumbleCallCoordinator.swift
//  MumbleSample
//
//  Created by 陳逸煌 on 2025/10/28.
//

class MumbleCallCoordinator: CallCoordinator {
    
    static var shared: MumbleCallCoordinator = .init(config: .test)
            
    var config: MumbleConfig
 
    var callKitReady: Bool = false
    
    var serverReady: Bool = false
    
    var callControllable: CallControllable?
    
    var callKitManager: CallKitManager
    
    var mumbleConnector: MumbleConnector
    
    var voIPPushManager: VoIPPushManager
        
        
    init(
        config: MumbleConfig,
        callKitManager: CallKitManager = CallKitManagerImpl(),
        mumbleConnector: MumbleConnector = MumbleConnectorImpl(),
        voIPPushManager: VoIPPushManager = VoIPPushManager()
    ) {
        self.config = config
        self.callKitManager = callKitManager
        self.mumbleConnector = mumbleConnector
        self.voIPPushManager = voIPPushManager
        
        self.callKitManager.callDelegate = self
        self.mumbleConnector.connectionDelegate = self
        self.voIPPushManager.delegate = self
    }

}


extension MumbleCallCoordinator: CallDelegate {
    
    func endCall() {
        self.mumbleConnector.stop()
    }
    
    func setCallKitReady(_ ready: Bool) {
        self.callKitReady = ready
        self.startAudioIfCan()
    }
    
    func answerIncoming(from display: String, channelID: UInt) {
        self.mumbleConnector.startConnect(with: channelID)
    }
}

extension MumbleCallCoordinator: MumbleConnectionDelegate {
    
    func getConfig() -> MumbleConfig {
        return self.config
    }
    
    
    func endConnected() {
        self.callKitManager.endCallFromRemote()
    }
    
    func startCallKitOutgoing(to user: String, channelID: UInt) {
        self.callKitManager.startOutgoing(to: user, channelID: channelID)
    }
    
    
    func startAudioIfCan() {
        guard self.callKitReady, self.serverReady else {
            print("callKitReady: \(self.callKitReady), serverReady: \(self.serverReady)")
            return
        }
        self.mumbleConnector.startAudio()
    }
    
    func setServerReady(_ ready: Bool) {
        self.serverReady = ready
        self.startAudioIfCan()
    }
    
    
}

extension MumbleCallCoordinator: ReportCallDelegate {
    
    func reportCallKitIncoming(from display: String, channelID: UInt) {
        self.callKitManager.reportIncoming(from: display, channelID: channelID)
    }
    
}

extension MumbleCallCoordinator: CallControllable {
    
    func requestOutgoingCall(to user: String, channelID: UInt) {
        self.mumbleConnector.makeCallWithCreateAChannel(to: user)
    }
    
    func toggleMute() -> Bool {
        return self.mumbleConnector.toggleMuted()
    }
    
    func toggleDeafen() -> Bool {
        return self.mumbleConnector.toggleSelfDeafened()
    }
    
    
    func setStateDelegate(delegate: any MumbleStateDelegate) {
        self.mumbleConnector.stateDelegate = delegate
    }
    
    
}

