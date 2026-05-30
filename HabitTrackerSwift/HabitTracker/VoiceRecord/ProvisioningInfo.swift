import Foundation

// Reads the embedded.mobileprovision file shipped inside the .app bundle
// and extracts the certificate ExpirationDate so we can show the user how
// many days remain before the free-Apple-ID 7-day signing window expires
// and the app has to be re-deployed.
//
// The file is a CMS-wrapped plist (binary signature wrapper, plist inside).
// We don't actually verify the signature — we just scan the file bytes for
// the embedded plist <?xml ... </plist> region and decode it. This is the
// standard pattern documented at process-one.net / Chris Mash's article.
//
// Why not store install date ourselves on first launch?
//   Because the user may install fresh every day during heavy development.
//   The provisioning profile's ExpirationDate is the SOURCE OF TRUTH —
//   tells us exactly when iOS will lock us out, not when we last installed.

enum ProvisioningInfo {
    // Days remaining until the embedded provisioning profile expires.
    // Returns nil when the profile cannot be parsed (e.g., simulator build
    // where embedded.mobileprovision is absent).
    static func daysUntilExpiry() -> Int? {
        guard let expiry = expirationDate() else { return nil }
        let secs = expiry.timeIntervalSinceNow
        return Int(ceil(secs / 86_400))
    }

    static func expirationDate() -> Date? {
        guard let url = Bundle.main.url(forResource: "embedded",
                                        withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        // Slice the embedded XML plist out of the CMS wrapper. The plist
        // begins with `<?xml` (or `<plist`) and ends with `</plist>`. Scan
        // for those markers as raw byte ranges — no need to coerce the
        // whole blob to a String (binary bytes outside the plist break
        // String(data:encoding:) on some profiles).
        let startMarker = Data("<?xml".utf8)
        let endMarker = Data("</plist>".utf8)
        guard let start = data.range(of: startMarker)?.lowerBound,
              let end = data.range(of: endMarker)?.upperBound,
              start < end else {
            return nil
        }
        let plistData = data.subdata(in: start..<end)
        guard let plist = try? PropertyListSerialization.propertyList(from: plistData,
                                                                     options: [],
                                                                     format: nil) as? [String: Any],
              let exp = plist["ExpirationDate"] as? Date else {
            return nil
        }
        return exp
    }
}
