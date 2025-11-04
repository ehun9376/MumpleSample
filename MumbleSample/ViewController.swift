//
//  ViewController.swift
//  MumbleSample
//
//  Created by 陳逸煌 on 2025/10/15.
//

import UIKit
import AVFoundation

class ViewController: UIViewController {
    
    var coordinator: CallControllable = MumbleCallCoordinator.shared

    private let muteButton = UIButton(type: .system)
    private let deafenButton = UIButton(type: .system)
    private let callOtherButton = UIButton(type: .system)
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
        self.coordinator.setStateDelegate(delegate: self)
  
    }

    private func setupUI() {

        self.muteButton.setTitle("Mic靜音: OFF", for: .normal)
        self.muteButton.setTitle("Mic靜音: ON", for: .selected)
        self.muteButton.addTarget(self, action: #selector(toggleMute), for: .touchUpInside)

        self.deafenButton.setTitle("全靜音: OFF", for: .normal)
        self.deafenButton.setTitle("全靜音: ON", for: .selected)
        self.deafenButton.addTarget(self, action: #selector(toggleDeafen), for: .touchUpInside)
        
        self.callOtherButton.setTitle("打給別人(Mock)", for: .normal)
        self.callOtherButton.addTarget(self, action: #selector(callOther), for: .touchUpInside)
        
        

        let stack = UIStackView(arrangedSubviews: [callOtherButton, muteButton, deafenButton ])
        stack.axis = .vertical
        stack.spacing = 16
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        
       
        self.tableView.translatesAutoresizingMaskIntoConstraints = false
        self.tableView.dataSource = self
        self.view.addSubview(self.tableView)


        self.view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: self.view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: self.view.safeAreaLayoutGuide.topAnchor, constant: 120),
            
            self.tableView.topAnchor.constraint(equalTo: stack.bottomAnchor, constant: 16),
            self.tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            self.tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            self.tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20)
        ])
    }

    private func updateButtons(enabled: Bool) {
        self.muteButton.isEnabled = enabled
        self.deafenButton.isEnabled = enabled
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
    
    private func reloadChannelList(model: MKServerModel) {
        guard let root = model.rootChannel() else { return }
        self.channelItems = []
        self.appendChannel(root, level: 0)
        self.tableView.reloadData()
    }
    
    private func appendChannel(_ channel: MKChannel, level: Int) {
        self.channelItems.append(ChannelDisplayItem(name: channel.channelName() ?? "", level: level, isUser: false, channel: channel))

        // 該頻道內的使用者
        if let users = channel.users() as? [MKUser] {
            for user in users {
                self.channelItems.append(ChannelDisplayItem(name: user.userName() ?? "", level: level + 1, isUser: true, channel: channel))
            }
        }

        // 子頻道
        if let children = channel.channels() as? [MKChannel] {
            for child in children {
                self.appendChannel(child, level: level + 1)
            }
        }
    }



    @objc private func toggleMute() {
        self.muteButton.isSelected = self.coordinator.toggleMute()
    }

    @objc private func toggleDeafen() {
        self.deafenButton.isSelected = self.coordinator.toggleDeafen()
    }
  
    
    @objc private func callOther() {
        self.coordinator.requestOutgoingCall(to: "Other", channelID: 2)
    }
}

extension ViewController: MumbleStateDelegate {
    func onModelChanged(model: MKServerModel) {
        
        DispatchQueue.main.async {  [weak self] in
            guard let self else { return }
            self.reloadChannelList(model: model)
        }
        
    }
    

    func onUserTalkStateChanged(user: MKUser, isTalking: Bool) {
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
    
    func onConnectionStateChange(status: ConnectionState) {
        DispatchQueue.main.async {  [weak self] in
            guard let self else { return }
            switch status {
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
    
    
    
}

extension ViewController: UITableViewDataSource {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return channelItems.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: "cell")
        let item = channelItems[indexPath.row]
        let indent = String(repeating: "    ", count: item.level)
        cell.textLabel?.text = indent + item.name + "  ID: \(item.channel.channelId())"
        cell.textLabel?.numberOfLines = 0
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
