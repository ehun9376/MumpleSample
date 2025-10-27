//
//  MumbleConnector+LocalStore.swift
//  MumbleSample
//
//  Created by 陳逸煌 on 2025/10/23.
//

extension MumbleConnector {
    func makeClientSSLArray(localData: Data? = nil, from mkCert: MKCertificate, password: String, userName: String) -> [Any]? {
        guard let p12Data = localData ?? mkCert.exportPKCS12(withPassword: password) else {
            print("❌ exportPKCS12 failed")
            return nil
        }

        var items: CFArray?
        let options: [String: Any] = [kSecImportExportPassphrase as String: password]
        let status = SecPKCS12Import(p12Data as CFData, options as CFDictionary, &items)

        guard status == errSecSuccess,
              let imported = items as? [[String: Any]],
              let first = imported.first,
              let identityAny = first[kSecImportItemIdentity as String] else {
            print("❌ SecPKCS12Import failed (\(status))")
            return nil
        }

        let identity = identityAny as! SecIdentity

        // 取出完整鏈
        let certs = first[kSecImportItemCertChain as String] as? [SecCertificate] ?? []

        // SSL 要求格式：[SecIdentity, SecCertificate...]
        var sslArray: [Any] = [identity]
        sslArray.append(contentsOf: certs)
        
        self.storeP12InKeychain(p12Data: p12Data, password: password, userName: userName)

        return sslArray
    }
    
    func storeP12InKeychain(p12Data: Data, password: String, userName: String) {
        // 1️⃣ 找到 Documents 目錄
        guard let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let fileURL = documentsURL.appendingPathComponent("\(userName).p12")

        do {
            // 2️⃣ 寫入 .p12
            try p12Data.write(to: fileURL, options: .atomic)
            print("💾 p12 憑證已儲存成功：\(fileURL.path)")
        } catch {
            print("❌ 儲存 p12 憑證失敗：\(error)")
        }
    }

    
    func loadP12FromKeychain(userName: String) -> Data?  {
        guard let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        let fileURL = documentsURL.appendingPathComponent("\(userName).p12")

        if let p12Data = try? Data(contentsOf: fileURL) {
            print("📦 讀取成功，大小：\(p12Data.count) bytes")
            return p12Data
        } else {
            return nil
        }
    }

}
