//
//  MumbleStateDelegate.swift
//  MumbleSample
//
//  Created by 陳逸煌 on 2025/10/28.
//

protocol MumbleStateDelegate {
    /// 有新增移除頻道、使用者加入、使用者移動頻道等事件時觸發
    func onModelChanged(model: MKServerModel)

    /// 使用者講話狀態改變時觸發
    func onUserTalkStateChanged(user: MKUser, isTalking: Bool)

    /// 連線狀態改變時觸發
    func onConnectionStateChange(status: ConnectionState)
}
