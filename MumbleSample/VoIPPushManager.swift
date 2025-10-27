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
    static let shared = VoIPPushManager()
    private var registry: PKPushRegistry?

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
        // 上傳 token 到你的伺服器
    }

    // App 在前景/背景/未開啟時都會走這裡（iOS 13+ 要在幾秒內呼叫 CallKit）
    func pushRegistry(_ registry: PKPushRegistry,
                      didReceiveIncomingPushWith payload: PKPushPayload,
                      for type: PKPushType,
                      completion: @escaping () -> Void) {

        let dict = payload.dictionaryPayload
        let caller = (dict["caller"] as? String) ?? "Unknown"
        let channelID = dict["channelID"] as? String

        // 顯示全螢幕來電畫面
        CallKitManager.shared.reportIncoming(from: caller,
                                             channelID: channelID)

        completion()
    }

    // iOS 13+ 建議實作（處理重複/過時的推播）
    func pushRegistry(_ registry: PKPushRegistry,
                      didInvalidatePushTokenFor type: PKPushType) {
        print("⚠️ VoIP token invalidated")
        // 通知伺服器刪除舊 token
    }
}
