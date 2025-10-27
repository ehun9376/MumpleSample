//
//  ViewController.swift
//  MumbleSample
//
//  Created by 陳逸煌 on 2025/10/15.
//

import UIKit
import AVFoundation

class ViewController: UIViewController {
    
    let connector = MumbleConnector.shared


    // 簡易 UI
    private let connectButton = UIButton(type: .system)
    private let muteButton = UIButton(type: .system)
    private let deafenButton = UIButton(type: .system)
    private let disconnectButton = UIButton(type: .system)
    private let createChannelButton = UIButton(type: .system)
    private let tableView = UITableView()

    
    private var channelItems: [ChannelDisplayItem] = []
    private var talkingUsers = Set<String>() // 用戶名集合



    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .white

        self.setupUI()
        self.updateButtons(enabled: false)

        // 麥克風權限
        self.requestMicPermissionIfNeeded()
        self.setupConnector()
  
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
        
        createChannelButton.setTitle("創立新頻道", for: .normal)
        createChannelButton.addTarget(self, action: #selector(createChannel), for: .touchUpInside)
        
        

        let stack = UIStackView(arrangedSubviews: [connectButton, muteButton, deafenButton, createChannelButton, disconnectButton])
        stack.axis = .vertical
        stack.spacing = 16
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        
       
        self.tableView.translatesAutoresizingMaskIntoConstraints = false
        self.tableView.delegate = self
        self.tableView.dataSource = self
        self.view.addSubview(self.tableView)


        self.view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: self.view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: self.view.safeAreaLayoutGuide.topAnchor, constant: 95),
            
            self.tableView.topAnchor.constraint(equalTo: stack.bottomAnchor, constant: 16),
            self.tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            self.tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            self.tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20)
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
    
    func setupConnector() {
        

        connector.onConnectionStateChange = { [weak self] state in
            DispatchQueue.main.async {  [weak self] in
                guard let self else { return }
                switch state {
                case .connected:
                    self.updateButtons(enabled: true)
                    self.muteButton.isSelected = false
                    self.deafenButton.isSelected = false
                case .disconnected:
                    self.updateButtons(enabled: false)
                    self.talkingUsers.removeAll()
                    self.channelItems = []
                    self.tableView.reloadData()
                }
            }
        }
         
        connector.onModelChanged = {  [weak self] in
            guard let self else { return }
            DispatchQueue.main.async {  [weak self] in
                guard let self else { return }
                 self.reloadChannelList()
            }
            
        }
        
        connector.onUserTalkStateChanged = { [weak self] user, isTalking in
            guard let self else { return }
            if isTalking {
                self.talkingUsers.insert(user.userName())
            } else {
                self.talkingUsers.remove(user.userName())
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.tableView.reloadData()
            }
        }
    }
    

    @objc private func connectToMumble() {
        // 若已有連線，先中止
        self.updateButtons(enabled: false)
        self.connector.stop()
        self.connector.start()
    }
    
    private func reloadChannelList() {
        guard let root = connector.rootChannel else { return }
        channelItems = []
        appendChannel(root, level: 0)
        self.tableView.reloadData()
        print(channelItems)
    }
    
    private func appendChannel(_ channel: MKChannel, level: Int) {
        channelItems.append(ChannelDisplayItem(name: channel.channelName() ?? "", level: level, isUser: false, channel: channel))

        // 該頻道內的使用者
        if let users = channel.users() as? [MKUser] {
            for user in users {
                channelItems.append(ChannelDisplayItem(name: user.userName() ?? "", level: level + 1, isUser: true, channel: channel))
            }
        }

        // 子頻道
        if let children = channel.channels() as? [MKChannel] {
            for child in children {
                appendChannel(child, level: level + 1)
            }
        }
    }



    @objc private func toggleMute() {
        let newMuted = !connector.isMuted
        connector.setMuted(newMuted)
        muteButton.isSelected.toggle()
    }

    @objc private func toggleDeafen() {
        let newDeaf = !connector.isSelfDeafened
        connector.setSelfDeafened(newDeaf)
        deafenButton.isSelected.toggle()
    }

    @objc private func disconnect() {
        CallKitManager.shared.endCall()
        connector.stop()
        updateButtons(enabled: false)
    }
    
    @objc private func createChannel() {
        
        
        
        if let first = self.channelItems.first(where: {$0.name.contains("openchannel")}) {
            connector.createChannel(name: "新頻道", parent: first.channel)
        }
        
    }
}

extension ViewController: UITableViewDataSource {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return channelItems.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: "cell")
        let item = channelItems[indexPath.row]
        let indent = String(repeating: "    ", count: item.level)
        cell.textLabel?.text = indent + item.name + "ID: \(item.channel.channelId())"

        if item.isUser {
            if talkingUsers.contains(item.name.replacingOccurrences(of: "👤 ", with: "")) {
                cell.textLabel?.textColor = .systemGreen
                cell.textLabel?.font = .boldSystemFont(ofSize: 16)
            } else {
                cell.textLabel?.textColor = .label
                cell.textLabel?.font = .systemFont(ofSize: 16)
            }
        } else {
            cell.textLabel?.textColor = .systemGray 
        }
        return cell
    }
}


extension ViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let item = channelItems[indexPath.row]
        guard !item.isUser else { return } // 只讓頻道可以被選

        // 根據名字找出實際的 channel
        if let root = connector.rootChannel {
            if let target = findChannel(named: item.name, in: root) {
                connector.join(channel: target)
            }
        }
    }

    private func findChannel(named name: String, in channel: MKChannel) -> MKChannel? {
        if channel.channelName() == name { return channel }
        for child in (channel.channels() as? [MKChannel]) ?? [] {
            if let found = findChannel(named: name, in: child) {
                return found
            }
        }
        return nil
    }
}
