// Registers <bundle id> as an explicit macOS App ID named <name> in Certificates, Identifiers & Profiles, or prints the
// one that exists. Usage: swift scripts/register-app-id.swift <bundle id> <name>, with ASC_KEY_ID, ASC_ISSUER_ID and
// ASC_KEY_PATH set (an App Store Connect API key with the Admin or App Manager role).
import CryptoKit
import Foundation

let env = ProcessInfo.processInfo.environment
let bundleID = CommandLine.arguments[1]
let name = CommandLine.arguments[2]

func base64URL(_ data: Data) -> String {
    data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

let key = try P256.Signing.PrivateKey(pemRepresentation: String(contentsOfFile: env["ASC_KEY_PATH"]!, encoding: .utf8))
let now = Int(Date().timeIntervalSince1970)
let header = try JSONSerialization.data(withJSONObject: ["alg": "ES256", "kid": env["ASC_KEY_ID"]!, "typ": "JWT"])
let claims = try JSONSerialization.data(withJSONObject: [
    "iss": env["ASC_ISSUER_ID"]!, "iat": now, "exp": now + 600, "aud": "appstoreconnect-v1",
])
let unsigned = base64URL(header) + "." + base64URL(claims)
let token = unsigned + "." + base64URL(try key.signature(for: Data(unsigned.utf8)).rawRepresentation)

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("register-app-id.swift: \(message)\n".utf8))
    exit(1)
}

func send(_ method: String, _ path: String, query: [String: String] = [:], body: Any? = nil) async throws -> [String: Any] {
    var url = URLComponents(string: "https://api.appstoreconnect.apple.com/v1/\(path)")!
    if !query.isEmpty { url.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
    var request = URLRequest(url: url.url!)
    request.httpMethod = method
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    if let body {
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
    }
    let (data, response) = try await URLSession.shared.data(for: request)
    guard (200..<300).contains((response as! HTTPURLResponse).statusCode) else {
        FileHandle.standardError.write(data)
        fail("\(method) \(path) failed")
    }
    return try JSONSerialization.jsonObject(with: data) as! [String: Any]
}

let existing = try await send("GET", "bundleIds", query: ["filter[identifier]": bundleID, "filter[platform]": "MAC_OS"])["data"] as! [[String: Any]]
if let found = existing.first(where: { ($0["attributes"] as! [String: Any])["identifier"] as? String == bundleID }) {
    print("already registered: \(bundleID) as \"\((found["attributes"] as! [String: Any])["name"] as! String)\" (id \(found["id"]!))")
    exit(0)
}
let made = try await send("POST", "bundleIds", body: [
    "data": ["type": "bundleIds", "attributes": ["identifier": bundleID, "name": name, "platform": "MAC_OS"]],
])["data"] as! [String: Any]
print("registered: \(bundleID) as \"\(name)\" (id \(made["id"]!))")
