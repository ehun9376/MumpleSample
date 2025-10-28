//
//  VoIPPushManager.swift
//  MumbleSample
//
//  Created by 陳逸煌 on 2025/10/23.
//

import Foundation
import PushKit
import UIKit

class VoIPPushManager: NSObject {
    
    var callCoordinator: CallCoordinator?
    
    private var registry: PKPushRegistry?
    
    override init() {
        super.init()
        self.start()
    }

    func start() {
        let reg = PKPushRegistry(queue: .main)
        reg.delegate = self
        reg.desiredPushTypes = [.voIP]
        self.registry = reg
    }
}

extension VoIPPushManager: PKPushRegistryDelegate {

    func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
        let token = pushCredentials.token.map { String(format: "%02.2hhx", $0) }.joined()

        print("📲 VoIP token: \(token)")
        
        //TODO 儲存VOIP Token 更新至Masa Server
    }

    func pushRegistry(_ registry: PKPushRegistry,
                      didReceiveIncomingPushWith payload: PKPushPayload,
                      for type: PKPushType,
                      completion: @escaping () -> Void) {

        let dict = payload.dictionaryPayload
        let caller = (dict["caller"] as? String) ?? "Unknown"
        let channelID = dict["channelID"] as? UInt ?? 0
        self.callCoordinator?.reportCallKitIncoming(from: caller,
                                             channelID: channelID)

        completion()
    }

    func pushRegistry(_ registry: PKPushRegistry,
                      didInvalidatePushTokenFor type: PKPushType) {
        print("⚠️ VoIP token invalidated")
    }
}
