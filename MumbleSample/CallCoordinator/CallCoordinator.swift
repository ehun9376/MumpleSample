//
//  CallCoordinator.swift
//  MumbleSample
//
//  Created by 陳逸煌 on 2025/10/28.
//

protocol CallCoordinator: AnyObject {
    
    /// 給UI呼叫，請求Mumble連線
    func requestMumbleOutgoing(to user: String, channelID: UInt)
    
    /// 給UI呼叫，請求Mumble關閉麥克風
    func toggleMute()
    
    /// 給UI呼叫，請求Mumble關閉麥克風且靜音
    func toggleDeafen()
    
    /// Mumble連線後呼叫，通知CallKit進入打電話狀態
    func startCallKitOutgoing(to user: String, channelID: UInt)
    
    /// 給VOIP Manager呼叫，通知有通話
    func reportCallKitIncoming(from display: String, channelID: UInt)
    
    /// CallKit接聽後呼叫這個func，通知Mumble連線
    func answerIncoming(from display: String, channelID: UInt)
    
    /// CallKit結束通話後呼叫Mumble結束連線
    func endMumbleConnect()
    
    /// 在CallKit進入通話狀態&MumbleServer連線後設定語音，提早設定會導致沒有辦法通話
    func startAudioIfCan()
    
    /// Mumble Server連線成功後通知CallCoordinator 已經連線
    func setServerReady(_ ready: Bool)
    
    /// CallKit建立通話成功後通知CallCoordinator 已經建立
    func setCallKitReady(_ ready: Bool)
    
    /// 設定Mumble的Delegate，狀態更新時通知UI更新。
    func setMumbleDelegate(delegate: MumbleClientDelegate)
    
    /// 登入後初始化 CallCoordinator時丟入config
    var config: MumbleConfig { get }
        
    var callKitReady: Bool { get set }
    
    var serverReady: Bool { get set }
    
    
    
}




