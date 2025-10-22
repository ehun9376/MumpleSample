//
//  ViewController.swift
//  MumbleSample
//
//  Created by 陳逸煌 on 2025/10/15.
//

import UIKit
import AVFoundation

class ViewController: UIViewController {

    // 保留強參考，避免連線物件被釋放
    private var connector: MumbleConnector?

    // 簡易 UI
    private let connectButton = UIButton(type: .system)
    private let muteButton = UIButton(type: .system)
    private let deafenButton = UIButton(type: .system)
    private let disconnectButton = UIButton(type: .system)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .white

        setupUI()
        updateButtons(enabled: false)

        // 麥克風權限
        requestMicPermissionIfNeeded()
        
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { notif in
            print("⚠️ AudioSession interruption:", notif.userInfo ?? [:])
            try? AVAudioSession.sharedInstance().setActive(true)
        }

    }

    private func setupUI() {
        connectButton.setTitle("Connect to Mumble", for: .normal)
        connectButton.titleLabel?.font = .systemFont(ofSize: 18, weight: .bold)
        connectButton.addTarget(self, action: #selector(connectToMumble), for: .touchUpInside)

        muteButton.setTitle("Mic靜音: OFF", for: .normal)
        muteButton.setTitle("Mic靜音: ON", for: .selected)
        muteButton.addTarget(self, action: #selector(toggleMute), for: .touchUpInside)

        deafenButton.setTitle("全靜音: OFF", for: .normal)
        deafenButton.setTitle("全靜音: ON", for: .selected)
        deafenButton.addTarget(self, action: #selector(toggleDeafen), for: .touchUpInside)

        disconnectButton.setTitle("Disconnect", for: .normal)
        disconnectButton.addTarget(self, action: #selector(disconnect), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [connectButton, muteButton, deafenButton, disconnectButton])
        stack.axis = .vertical
        stack.spacing = 16
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }

    private func updateButtons(enabled: Bool) {
        muteButton.isEnabled = enabled
        deafenButton.isEnabled = enabled
        disconnectButton.isEnabled = enabled
    }

    private func requestMicPermissionIfNeeded() {
        switch AVAudioSession.sharedInstance().recordPermission {
        case .granted:
            break
        case .denied:
            print("Microphone permission denied.")
        case .undetermined:
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                print("Mic permission: \(granted)")
            }
        @unknown default:
            break
        }
    }

    @objc private func connectToMumble() {
        // 若已有連線，先中止
        connector?.stop()
        updateButtons(enabled: false)

        let connector = MumbleConnector(
            host: "uat-voip.1111job.app",
            port: 64738,
            username: "Ehun dev",
            password: "52@11118888",
            accessTokens: nil,
            allowSelfSigned: false,
            forceTCP: true
        )
        connector.onConnectionStateChange = { [weak self] state in
            DispatchQueue.main.async {
                switch state {
                case .connected:
                    self?.updateButtons(enabled: true)
                    self?.muteButton.isSelected = false
                    self?.deafenButton.isSelected = false
                case .disconnected:
                    self?.updateButtons(enabled: false)
                }
            }
        }
        self.connector = connector
        connector.start()
    }

    @objc private func toggleMute() {
        guard let connector else { return }
        let newMuted = !connector.isMuted
        connector.setMuted(newMuted)
        muteButton.isSelected.toggle()
    }

    @objc private func toggleDeafen() {
        guard let connector else { return }
        let newDeaf = !connector.isSelfDeafened
        connector.setSelfDeafened(newDeaf)
        deafenButton.isSelected.toggle()
    }

    @objc private func disconnect() {
        connector?.stop()
        updateButtons(enabled: false)
    }
}
