# MumbleSample

## 專案簡介
MumbleSample 是一個以 Swift 撰寫的 iOS 示範應用程式，展示如何透過 [MumbleKit](mumblekit/README.markdown) 與 Mumble 語音伺服器建立連線、啟動雙向語音串流並控制靜音狀態。應用程式維持極簡 UI，聚焦在 AVAudioSession 設定、MumbleKit 連線流程與音訊傳輸的整合細節。

## 功能特色
- 以 `MKConnection` 建立 TLS/TCP 連線並透過 `MKServerModel` 管理伺服器狀態。
- 自動啟用 Opus 編碼、配置 `AVAudioSession`，並開啟持續傳輸避免語音活動偵測失效。
- 提供連線、麥克風靜音、自身靜音 (self-deafen)、中斷連線等基本操作。
- 以 Swift/Objective-C 橋接頭檔(`MumbleSample/Mumble-Bridging-Header.h`) 暴露 MumbleKit API。

## 專案結構
- `MumbleSample/ViewController.swift`：建立簡易 UI 與許可流程，並呼叫 `MumbleConnector`。
- `MumbleSample/MumbleConnector.swift`：封裝 MumbleKit 連線、驗證、音訊啟動與狀態回報。
- `MumbleSample/mumblekit/`：嵌入的 MumbleKit 原始碼與相關資源。若以子模組方式取得，請確保已同步。
- 其餘檔案為標準 iOS 專案檔 (`AppDelegate`, `SceneDelegate`, `Info.plist`, Assets 等)。

## 系統需求
- macOS 與 Xcode 15 以上版本。
- iOS 16.6 以上部署目標 (參考 `MumbleSample.xcodeproj/project.pbxproj`)。
- 實體裝置建議：需麥克風與揚聲器以驗證語音功能。

## 快速開始
1. 取得原始碼
   ```bash
   git clone <repo-url>
   cd MumbleSample
   git submodule update --init --recursive   # 若 mumblekit 以子模組管理
   ```
2. 以 Xcode 開啟 `MumbleSample.xcodeproj`，選擇 `MumbleSample` target。
3. 依需求修改預設伺服器連線資訊：
   - 主機、連線設定：`MumbleSample/MumbleConnector.swift`
   - UI 建立連線時的帳號密碼：`MumbleSample/ViewController.swift`
4. 連線前請確認裝置麥克風權限，或於應用程式首次啟動時授權。
5. 建議於實機執行以驗證輸入/輸出路徑，並使用具備 Mumble 伺服器的測試環境。

## 連線與音訊流程
1. `ViewController` 透過按鈕建立 `MumbleConnector`，並設定狀態回呼以更新 UI。
2. `MumbleConnector.start()`：
   - 啟用 Opus (`MKVersion.shared().setOpusEnabled(true)`)。
   - 建立 `MKConnection`，設定忽略自簽章或強制 TCP 等選項後呼叫 `connect`.
   - 將 `MKServerModel` 設為訊息處理器，並監聽連線事件。
3. `MKServerModelDelegate` 在 `joinedServerAs` 中以 1 秒延遲呼叫 `startAudioAfterServerSync()`，確保伺服器同步完成。
4. `startAudioAfterServerSync()` 會：
   - 設定 `AVAudioSession` 類別為 `playAndRecord`，允許藍牙、混音與擴音器。
   - 讀取並更新 `MKAudioSettings`，啟用強制傳輸與自訂參數。
   - 綁定連線與音訊模組 (`setMainConnectionFor`)，並取消靜音。

## 參數與安全性注意事項
- 範例程式中的主機、帳密僅供測試；發佈前請改為使用者配置或安全儲存機制。
- 如需允許自簽章憑證，請設定 `allowSelfSigned = true`，並評估風險。
- 若伺服器不支援 UDP，`forceTCP = true` 可確保連線，但可能增加延遲。
- 確保 `NSMicrophoneUsageDescription` 已在 Info.plist 中設定，避免審核被拒。

## 延伸方向
- 加入伺服器/頻道瀏覽 UI 與文字聊天。
- 實作語音活動偵測切換，動態控制強制傳輸。
- 將憑證 pinning、自訂錯誤提示等安全性機制整合進 UI。
- 建立單元測試以驗證連線邏輯與錯誤處理 (目前僅有預設測試模組)。

## 授權
此專案包含的 `mumblekit/` 依原專案所示的授權條款 (MIT/GPL 相關) 使用；請於發佈前詳閱 `mumblekit/LICENSE` 與 `mumblekit/README.markdown`。

