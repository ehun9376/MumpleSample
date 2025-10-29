//
//  CallCoordinator.swift
//  MumbleSample
//
//  Created by 陳逸煌 on 2025/10/28.
//

protocol CallControllable {
    /// 給UI呼叫，請求Mumble連線
    func requestOutgoingCall(to user: String, channelID: UInt)
    
    /// 給UI呼叫，請求Mumble關閉麥克風
    func toggleMute() -> Bool
    
    /// 給UI呼叫，請求Mumble關閉麥克風且靜音
    func toggleDeafen() -> Bool
    
    /// 設定Mumble的Delegate，狀態更新時通知UI更新。
    func setStateDelegate(delegate: MumbleStateDelegate)
}

protocol MumbleConnectionDelegate {
    /// 登入後初始化 CallCoordinator時丟入config
    func getConfig() -> MumbleConfig
    
    /// Mumble Server連線成功後通知CallCoordinator 已經連線
    func setServerReady(_ ready: Bool)
    
    /// Mumble連線後呼叫，通知CallKit進入打電話狀態
    func startCallKitOutgoing(to user: String, channelID: UInt)
    
    /// Mumble結束連線後通知Delegate要結束連線
    func endConnected()
}

protocol ReportCallDelegate {
    /// 給VOIP Manager呼叫，通知有通話
    func reportCallKitIncoming(from display: String, channelID: UInt)
}

protocol CallDelegate: AnyObject {
    /// CallKit建立通話成功後通知CallCoordinator 已經建立
    func setCallKitReady(_ ready: Bool)
    
    /// CallKit接聽後呼叫這個func，通知Mumble連線
    func answerIncoming(from display: String, channelID: UInt)
    
    /// CallKit主動掛斷電話後呼叫
    func endCall()
}


protocol CallCoordinator: AnyObject {

    /// 在CallKit進入通話狀態&MumbleServer連線後設定語音，提早設定會導致沒有辦法通話
    func startAudioIfCan()

}




