import Foundation
import CallKit
import AVFAudio
import UIKit


/// 儲存一次來電所需的資料（從 VoIP Push 帶進來）
struct IncomingCallContext {
    let uuid: UUID
    let callerDisplay: String
    let channelID: String?
}

class CallKitManager: NSObject {
    static let shared = CallKitManager()

    private let provider: CXProvider
    private let controller = CXCallController()
    private var currentCall: IncomingCallContext?

    private override init() {
        
        // Use designated initializer and set properties to avoid deprecated API on iOS 14+
        let cfg = CXProviderConfiguration()
        cfg.ringtoneSound = nil
        cfg.supportsVideo = false
        cfg.maximumCallsPerCallGroup = 1
        cfg.supportedHandleTypes = Set<CXHandle.HandleType>([.generic])
        // 可選：顯示 App icon（單色模板）
        if let img = UIImage(named: "AppIcon")?.pngData() {
            cfg.iconTemplateImageData = img
        }
        provider = CXProvider(configuration: cfg)
        super.init()
        provider.setDelegate(self, queue: nil)
    }

    // MARK: - 顯示來電畫面
    func reportIncoming(from display: String,
                        channelID: String?) {
        let uuid = UUID()
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: display)
        update.hasVideo = false

        provider.reportNewIncomingCall(with: uuid, update: update) { [weak self] err in
            if let err = err {
                print("❌ reportNewIncomingCall failed: \(err)")
                return
            }
            print("📞 Incoming call from \(display)")
            self?.currentCall = IncomingCallContext(uuid: uuid,
                                                    callerDisplay: display,
                                                    channelID: channelID)
        }
    }
    
    

    // MARK: - 主動掛斷（如遠端取消）
    func endCall(reason: CXCallEndedReason = .remoteEnded) {
        guard let ctx = currentCall else { return }
        provider.reportCall(with: ctx.uuid, endedAt: Date(), reason: reason)
        currentCall = nil
        MumbleConnector.shared.stop()
    }

    // MARK: - 主動撥出（如要做類似 LINE 主叫方）
    func startOutgoing(to display: String,
                       channelName: String?) {
        let uuid = UUID()
        let handle = CXHandle(type: .generic, value: display)
        let startAction = CXStartCallAction(call: uuid, handle: handle)
        let tx = CXTransaction(action: startAction)

        controller.request(tx) { [weak self] err in
            if let err = err {
                print("❌ startOutgoing failed: \(err)")
                return
            }
            self?.currentCall = IncomingCallContext(uuid: uuid,
                                                    callerDisplay: display,
                                                    channelID: channelName)
            // 告訴 CallKit 正在呼叫對方
            let update = CXCallUpdate()
            update.remoteHandle = handle
            self?.provider.reportCall(with: uuid, updated: update)
            self?.provider.reportOutgoingCall(with: uuid, startedConnectingAt: Date())
        }
    }

    func endOutgoing() {
        endCall(reason: .remoteEnded)
    }
}

extension CallKitManager: CXProviderDelegate {

    // 使用者按「接聽」
    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        print("✅ CallKit: Answer")
        action.fulfill()
        // 等待系統把 AudioSession 交給我們（看下面 didActivate）
    }

    // 使用者按「掛斷」
    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        print("🟥 CallKit: End")
        action.fulfill()
        MumbleConnector.shared.stop()
        currentCall = nil
    }

    // 撥出開始
    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        print("📤 CallKit: Start outbound")
        provider.reportOutgoingCall(with: action.callUUID, connectedAt: Date())
        action.fulfill()
        // 等待 didActivate 再開音訊
    }

    // 系統音訊「交給」App（這時再開始 Mumble，避免跟系統音訊搶）
    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        print("🎧 CallKit didActivate, start Mumble now")
        guard let ctx = currentCall else { return }
        // 開始連線 Mumble（你已經有 MumbleConnector）
        MumbleConnector.shared.startCall(targetChannelID: ctx.channelID ?? "")
    }

    // 系統音訊「收回」
    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        print("🔇 CallKit didDeactivate")
        // 結束通話
        MumbleConnector.shared.stop()
    }

    func providerDidReset(_ provider: CXProvider) {
        print("♻️ CallKit providerDidReset")
        currentCall = nil
        MumbleConnector.shared.stop()
    }
}
