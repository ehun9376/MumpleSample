import Foundation
import AVFAudio
import CallKit

protocol CallKitManager {
    func reportIncoming(from display: String, channelID: UInt)
    func startOutgoing(to display: String, channelID: UInt)
    func endCallFromRemote()
    var callDelegate: CallDelegate? { get set }
}

class CallKitManagerImpl: NSObject, CallKitManager {

    private let provider: CXProvider
    private let controller = CXCallController()
    private var newCall: IncomingCallContext?
    private var currentCall: IncomingCallContext?
    
    var callDelegate: CallDelegate?

    override init() {
        let cfg = CXProviderConfiguration(localizedName: "1111 VOIP")
        cfg.supportsVideo = false
        cfg.maximumCallsPerCallGroup = 1
        cfg.supportedHandleTypes = [.generic]
        cfg.ringtoneSound = "ringtone.caf"
        cfg.includesCallsInRecents = false

        if let img = UIImage(named: "AppIcon")?.pngData() {
            cfg.iconTemplateImageData = img
        }

        provider = CXProvider(configuration: cfg)
        super.init()
        provider.setDelegate(self, queue: nil)
    }
    
    
    /// 當收到 VoIP 推播後呼叫這個方法
    func reportIncoming(from display: String, channelID: UInt) {
        let uuid = UUID()
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: display)
        update.hasVideo = false
        update.localizedCallerName = display

        provider.reportNewIncomingCall(with: uuid, update: update) { [weak self] err in
            if let err = err {
                print("❌ reportNewIncomingCall failed: \(err)")
                return
            }
            print("📞 Incoming call from \(display)")
            self?.newCall = IncomingCallContext(uuid: uuid,
                                                    callerDisplay: display,
                                                    channelID: channelID)
        }
    }
    
    func startOutgoing(to display: String, channelID: UInt) {
        let uuid = UUID()
        let handle = CXHandle(type: .generic, value: display)
        let startAction = CXStartCallAction(call: uuid, handle: handle)
        let tx = CXTransaction(action: startAction)

        controller.request(tx) { [weak self] err in
            if let err = err {
                print("❌ startOutgoing failed: \(err)")
                return
            }

            guard let self else { return }
            self.currentCall = IncomingCallContext(uuid: uuid,
                                                   callerDisplay: display,
                                                   channelID: channelID)

            let update = CXCallUpdate()
            update.remoteHandle = handle
            update.localizedCallerName = display
            update.hasVideo = false
            self.provider.reportCall(with: uuid, updated: update)
            self.provider.reportOutgoingCall(with: uuid, startedConnectingAt: Date())

            // 延遲一點讓系統註冊通話狀態
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.provider.reportOutgoingCall(with: uuid, connectedAt: Date())
            }
        }
    }

    func endCall(reason: CXCallEndedReason = .remoteEnded) {
        if let ctx = currentCall {
            self.provider.reportCall(with: ctx.uuid, endedAt: Date(), reason: reason)
        }
        self.currentCall = nil
        self.callDelegate?.endCall()
    }
    
    func endCallFromRemote() {
        self.endCall(reason: .remoteEnded)
    }
}

// MARK: - CallKit Delegate
extension CallKitManagerImpl: CXProviderDelegate {

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        print("✅ CallKit: Answer")
        
        //如果有舊的就，不管是保留還是掛斷後接聽，都是強制先結束舊的，
        if let ctx = self.currentCall {
            print("🧹 結束舊通話 \(ctx.callerDisplay)")
            provider.reportCall(with: ctx.uuid, endedAt: Date(), reason: .answeredElsewhere)
            self.enableProximitySensor(false)
            self.endCall()
        }

        //處理新的來電
        if let ctx = self.newCall {
            action.fulfill()
            self.enableProximitySensor(true)
            self.callDelegate?.answerIncoming(from: ctx.callerDisplay, channelID: ctx.channelID)
            self.currentCall = ctx
            self.newCall = nil
        }
      

      
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        print("🟥 CallKit: End")
        action.fulfill()
        self.enableProximitySensor(false)
        self.endCall()
    }

    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        print("📤 CallKit: Start outgoing")
        action.fulfill()
    }

    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        print("🎧 CallKit didActivate, start Mumble now")
        self.callDelegate?.setCallKitReady(true)
    }

    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        print("🔇 Audio deactivated")
    }

    func providerDidReset(_ provider: CXProvider) {
        print("♻️ CallKit reset")
        self.endCall()
    }
}

// MARK: - Proximity Sensor
extension CallKitManagerImpl {

    func enableProximitySensor(_ enabled: Bool) {
        let device = UIDevice.current
        device.isProximityMonitoringEnabled = enabled

        if enabled {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleProximityChange),
                name: UIDevice.proximityStateDidChangeNotification,
                object: device
            )
        } else {
            NotificationCenter.default.removeObserver(
                self,
                name: UIDevice.proximityStateDidChangeNotification,
                object: device
            )
        }

        print("📱 Proximity sensor \(enabled ? "enabled" : "disabled")")
    }

    @objc private func handleProximityChange(_ note: Notification) {
        if UIDevice.current.proximityState {
            print("👂 Near ear — screen off")
        } else {
            print("📴 Moved away — screen on")
        }
    }
}
