import Foundation

enum SonioxError: LocalizedError {
    case missingAPIKey
    case mintFailed(status: Int, body: String)
    case decode(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Soniox API key is missing. Paste it into VoiceRecord/Secrets.swift."
        case .mintFailed(let status, let body):
            return "Soniox mint failed: HTTP \(status) — \(body)"
        case .decode(let msg):
            return "Soniox mint decode error: \(msg)"
        }
    }
}

// Mints a short-lived API key (5 min) using the long-lived key from Secrets.
// Matches what voice-record's main.js does on macOS, including the mandatory
// expires_in_seconds field (without it the API returns HTTP 400).
enum SonioxTokenMint {
    static func mintTemporaryKey() async throws -> String {
        VRLog.d("Mint", "begin — keyEmpty=\(Secrets.sonioxAPIKey.isEmpty)")
        guard !Secrets.sonioxAPIKey.isEmpty else { throw SonioxError.missingAPIKey }
        var req = URLRequest(url: URL(string: VoiceRecordConfig.sonioxTokenURL)!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(Secrets.sonioxAPIKey)", forHTTPHeaderField: "Authorization")
        // Explicit 8s request timeout. Default URLSession.shared waits 60s on
        // a hung request; we'd rather surface a clean error to the user than
        // freeze on "Starting…" for a minute. Caller logs every step around
        // this call so a stall is visible in the log even before timeout.
        req.timeoutInterval = 8
        // usage_type + expires_in_seconds are BOTH required (verified against
        // voice-record's working main.js). Without usage_type the API returns
        // 400 invalid_request: {location: "body.payload.usage_type"}.
        let body: [String: Any] = [
            "usage_type": "transcribe_websocket",
            "expires_in_seconds": 300,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        VRLog.d("Mint", "POST → \(VoiceRecordConfig.sonioxTokenURL)")
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            VRLog.e("Mint", "POST failed: \(error.localizedDescription)")
            throw error
        }
        guard let http = response as? HTTPURLResponse else {
            VRLog.e("Mint", "non-HTTP response")
            throw SonioxError.decode("non-HTTP response")
        }
        VRLog.d("Mint", "← HTTP \(http.statusCode) bodyLen=\(data.count)")
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw SonioxError.mintFailed(status: http.statusCode, body: body)
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SonioxError.decode("not a JSON object")
        }
        if let key = obj["api_key"] as? String { VRLog.d("Mint", "ok keyLen=\(key.count)"); return key }
        if let key = obj["key"] as? String { VRLog.d("Mint", "ok keyLen=\(key.count) (key field)"); return key }
        if let key = obj["apiKey"] as? String { VRLog.d("Mint", "ok keyLen=\(key.count) (apiKey field)"); return key }
        throw SonioxError.decode("api_key not found in response")
    }
}
