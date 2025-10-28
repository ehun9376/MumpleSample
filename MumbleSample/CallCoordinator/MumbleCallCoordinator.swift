//
//  MumbleCallCoordinator.swift
//  MumbleSample
//
//  Created by 陳逸煌 on 2025/10/28.
//

class MumbleCallCoordinator: CallCoordinator {
    
    static var shared: MumbleCallCoordinator?
            
    var config: MumbleConfig
 
    var callKitReady: Bool = false
    
    var serverReady: Bool = false
    
    var callKitManager: CallKitManager
    
    var mumbleClient: MumbleConnectorImpl
    
    var voIPPushManager: VoIPPushManager
        
        
    init(
        config: MumbleConfig,
        callKitManager: CallKitManager = CallKitManager(),
        mumbleClient: MumbleConnectorImpl = MumbleConnectorImpl(),
        voIPPushManager: VoIPPushManager = VoIPPushManager()
    ) {
        self.config = config
        self.callKitManager = callKitManager
        self.mumbleClient = mumbleClient
        self.voIPPushManager = voIPPushManager
        
        self.callKitManager.coordinator = self
        self.mumbleClient.coordinator = self
        self.voIPPushManager.callCoordinator = self
    }
    
    func requestMumbleOutgoing(to user: String, channelID: UInt) {
        self.mumbleClient.makeCallWithCreateAChannel(to: user)
    }
    
    func startCallKitOutgoing(to user: String, channelID: UInt) {
        self.callKitManager.startOutgoing(to: user, channelID: channelID)
    }
    
    func reportCallKitIncoming(from display: String, channelID: UInt) {
        self.callKitManager.reportIncoming(from: display, channelID: channelID)
    }
    
    func answerIncoming(from display: String, channelID: UInt) {
        self.mumbleClient.answerCall(from: channelID)
    }
    
    func startAudioIfCan() {
        guard self.callKitReady, self.serverReady else {
            print("callKitReady: \(self.callKitReady), serverReady: \(self.serverReady)")
            return
        }
        self.mumbleClient.startAudio()
    }
    
    func setServerReady(_ ready: Bool) {
        self.serverReady = ready
        self.startAudioIfCan()
    }
    
    func setCallKitReady(_ ready: Bool) {
        self.callKitReady = ready
        self.startAudioIfCan()
    }
 
    
    func endMumbleConnect() {
        self.mumbleClient.stop()
    }
    
    func toggleMute() {
        self.mumbleClient.toggleMuted()
    }
    
    func toggleDeafen() {
        self.mumbleClient.toggleDeafened()
    }
    
    func setMumbleDelegate(delegate: any MumbleClientDelegate) {
        self.mumbleClient.delegate = delegate
    }


}


