//
//  MumbleConfig.swift
//  MumbleSample
//
//  Created by 陳逸煌 on 2025/10/28.
//

struct MumbleConfig {
    let host: String
    let port: UInt
    let username: String
    let serverPassword: String
    
    static let test: MumbleConfig = .init(
        host: "uat-voip.1111job.app",
        port: 64738,
        username: UUID().uuidString.prefix(8).description,
        serverPassword: "52@11118888"
    )
}
