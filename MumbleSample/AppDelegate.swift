//
//  AppDelegate.swift
//  MumbleSample
//
//  Created by 陳逸煌 on 2025/10/15.
//

import UIKit
import AVFAudio
import UserNotifications

@main
class AppDelegate: UIResponder, UIApplicationDelegate {

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {

        // 啟動 VoIP Push（取得 VoIP token）
        _ = CallKitManager.shared // 提前建立 provider

        VoIPPushManager.shared.start()

        // 音訊類別（CallKit 啟用後也會交由你的音訊處理）
        
        let session = AVAudioSession.sharedInstance()
        
        do {
            try session.setCategory(.playAndRecord,
                                    options: [.allowBluetoothHFP, .mixWithOthers])
            try session.setPreferredSampleRate(48000)
            print("✅ AVAudioSession active, inputAvailable:", session.isInputAvailable)
        } catch {
            print("❌ AVAudioSession setup failed:", error)
        }
        


        // 1) 申請通知權限（一般 APNs）
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, err in
            if let err {
                print("🔔 Notification authorization error: \(err)")
            }
            print("🔔 Notification authorization granted: \(granted)")

            // 2) 向 APNs 註冊（要在主執行緒）
            DispatchQueue.main.async {
                UIApplication.shared.registerForRemoteNotifications()
            }
        }
        


        // 顯示全螢幕來電畫面
//        CallKitManager.shared.reportIncoming(from: "Someone",
//                                             channelID: "2")


        return true
    }

    // MARK: - APNs callbacks (一般遠端通知的 token)

    // 成功取得 APNs token
    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let pushToken = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
        print("📨 APNs token: \(pushToken)")
        // TODO: 上傳 token 到你的伺服器
    }

    // 取得 APNs token 失敗
    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("❌ Failed to register for remote notifications: \(error)")
    }

    // MARK: UISceneSession Lifecycle

    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        return UISceneConfiguration(name: "Default Configuration",
                                    sessionRole: connectingSceneSession.role)
    }

    func application(_ application: UIApplication,
                     didDiscardSceneSessions sceneSessions: Set<UISceneSession>) {
        // 清理不再使用的 scene 資源
    }
}
