import Foundation

enum LinkedInError: LocalizedError {
    case message(String)
    case http(status: Int, body: String)

    var errorDescription: String? {
        switch self {
        case .message(let m):
            return m
        case .http(let status, let body):
            let detail = (try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])?["message"] as? String
            let hint: String = switch status {
            case 401: " Your LinkedIn sign-in has expired — reconnect in Settings."
            case 403: " LinkedIn refused the request; check the app has the \"Share on LinkedIn\" product."
            case 429: " LinkedIn rate limit hit; it will be retried."
            default: ""
            }
            return "LinkedIn returned \(status): \(detail ?? body.prefix(300).description).\(hint)"
        }
    }
}

/// Thin wrapper over the LinkedIn REST endpoints LinkedMgr uses:
/// Images and Videos (upload), Posts (create), socialActions/comments (first comment),
/// and organizations (vanity-name lookup for company tags).
struct LinkedInClient: Sendable {
    let token: String
    let personURN: String

    /// `Linkedin-Version` header (YYYYMM). LinkedIn sunsets versions after about a year.
    static var apiVersion: String {
        UserDefaults.standard.string(forKey: "apiVersion").flatMap { $0.isEmpty ? nil : $0 } ?? "202610"
    }

    // MARK: OAuth

    struct Token: Decodable {
        let accessToken: String
        let expiresIn: Int
        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case expiresIn = "expires_in"
        }
    }

    struct UserInfo: Decodable {
        let sub: String
        let name: String?
    }

    static func exchangeCode(_ code: String, clientID: String, clientSecret: String, redirectURI: String) async throws -> Token {
        var request = URLRequest(url: URL(string: "https://www.linkedin.com/oauth/v2/accessToken")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = [
            .init(name: "grant_type", value: "authorization_code"),
            .init(name: "code", value: code),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "client_id", value: clientID),
            .init(name: "client_secret", value: clientSecret),
        ]
        request.httpBody = form.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)
        let (data, _) = try await send(request)
        return try JSONDecoder().decode(Token.self, from: data)
    }

    static func userInfo(token: String) async throws -> UserInfo {
        var request = URLRequest(url: URL(string: "https://api.linkedin.com/v2/userinfo")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await send(request)
        return try JSONDecoder().decode(UserInfo.self, from: data)
    }

    // MARK: Images

    /// Uploads one image and returns its `urn:li:image:…`.
    func uploadImage(at url: URL) async throws -> String {
        struct Init: Decodable {
            struct Value: Decodable { let uploadUrl: String; let image: String }
            let value: Value
        }
        let body = ["initializeUploadRequest": ["owner": personURN]]
        let (data, _) = try await rest("POST", "images?action=initializeUpload", json: body)
        let initResponse = try JSONDecoder().decode(Init.self, from: data)

        var put = URLRequest(url: URL(string: initResponse.value.uploadUrl)!)
        put.httpMethod = "PUT"
        put.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        put.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        put.httpBody = try Data(contentsOf: url)
        _ = try await Self.send(put)
        return initResponse.value.image
    }

    // MARK: Videos

    /// Uploads a video in the parts LinkedIn asks for (4 MB each) and returns its `urn:li:video:…`.
    /// LinkedIn then processes it; check `videoStatus` before posting.
    func uploadVideo(at url: URL) async throws -> String {
        struct Init: Decodable {
            struct Part: Decodable { let uploadUrl: String; let firstByte: UInt64; let lastByte: UInt64 }
            struct Value: Decodable { let video: String; let uploadToken: String?; let uploadInstructions: [Part] }
            let value: Value
        }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        let body: [String: Any] = ["initializeUploadRequest": [
            "owner": personURN, "fileSizeBytes": size, "uploadCaptions": false, "uploadThumbnail": false,
        ]]
        let (data, _) = try await rest("POST", "videos?action=initializeUpload", json: body)
        let upload = try JSONDecoder().decode(Init.self, from: data).value

        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var partIDs: [String] = []
        for part in upload.uploadInstructions {
            try file.seek(toOffset: part.firstByte)
            var put = URLRequest(url: URL(string: part.uploadUrl)!)
            put.httpMethod = "PUT"
            put.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            put.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            put.httpBody = try file.read(upToCount: Int(part.lastByte - part.firstByte + 1)) ?? Data()
            let (_, response) = try await Self.send(put)
            guard let etag = response.value(forHTTPHeaderField: "ETag") else {
                throw LinkedInError.message("LinkedIn didn't confirm a video part upload (no ETag).")
            }
            partIDs.append(etag)
        }

        let finalize: [String: Any] = ["finalizeUploadRequest": [
            "video": upload.video, "uploadToken": upload.uploadToken ?? "", "uploadedPartIds": partIDs,
        ]]
        _ = try await rest("POST", "videos?action=finalizeUpload", json: finalize)
        return upload.video
    }

    /// `AVAILABLE`, `PROCESSING`, `WAITING_UPLOAD` or `PROCESSING_FAILED` (with a reason).
    func videoStatus(_ urn: String) async throws -> (status: String, failureReason: String?) {
        let (data, _) = try await rest("GET", "videos/\(Self.encode(urn))")
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (json?["status"] as? String ?? "", json?["processingFailureReason"] as? String)
    }

    // MARK: Posts

    /// Creates a public post and returns its URN (`urn:li:share:…` or `urn:li:ugcPost:…`).
    func createPost(commentary: String, images: [(urn: String, altText: String)],
                    video: (urn: String, title: String)? = nil) async throws -> String {
        let body = Self.postBody(author: personURN, commentary: commentary, images: images, video: video)
        let (_, response) = try await rest("POST", "posts", json: body)
        guard let urn = response.value(forHTTPHeaderField: "x-restli-id") else {
            throw LinkedInError.message("LinkedIn accepted the post but didn't return its ID.")
        }
        return urn
    }

    /// One image or one video goes in `content.media`; 2–20 images in `content.multiImage`.
    static func postBody(author: String, commentary: String, images: [(urn: String, altText: String)],
                         video: (urn: String, title: String)?) -> [String: Any] {
        var body: [String: Any] = [
            "author": author,
            "commentary": commentary,
            "visibility": "PUBLIC",
            "distribution": [
                "feedDistribution": "MAIN_FEED",
                "targetEntities": [],
                "thirdPartyDistributionChannels": [],
            ],
            "lifecycleState": "PUBLISHED",
            "isReshareDisabledByAuthor": false,
        ]
        func media(_ image: (urn: String, altText: String)) -> [String: Any] {
            image.altText.isEmpty ? ["id": image.urn] : ["id": image.urn, "altText": image.altText]
        }
        if let video {
            body["content"] = ["media": video.title.isEmpty ? ["id": video.urn] : ["id": video.urn, "title": video.title]]
        } else if images.count == 1 {
            body["content"] = ["media": media(images[0])]
        } else if images.count > 1 {
            body["content"] = ["multiImage": ["images": images.map(media)]]
        }
        return body
    }

    // MARK: Comments

    func createComment(on postURN: String, text: String, attributes: [LittleText.Attribute]) async throws -> String? {
        var message: [String: Any] = ["text": text]
        if !attributes.isEmpty {
            message["attributes"] = attributes.map { a -> [String: Any] in
                let isOrg = a.urn.hasPrefix("urn:li:organization:")
                let value: [String: Any] = isOrg
                    ? ["organization": ["organization": a.urn]]
                    : ["person": ["person": a.urn]]
                return ["start": a.start, "length": a.length, "value": value]
            }
        }
        let body: [String: Any] = ["actor": personURN, "object": postURN, "message": message]
        let (data, response) = try await rest("POST", "socialActions/\(Self.encode(postURN))/comments", json: body)
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return json?["commentUrn"] as? String ?? response.value(forHTTPHeaderField: "x-restli-id")
    }

    // MARK: Organizations

    struct Organization {
        let urn: String
        let name: String
    }

    /// Resolves a company page's vanity name (linkedin.com/company/<vanity>) to its URN.
    /// LinkedIn may refuse this for apps without organization permissions.
    func lookupOrganization(vanityName: String) async throws -> Organization? {
        let q = vanityName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? vanityName
        let (data, _) = try await rest("GET", "organizations?q=vanityName&vanityName=\(q)")
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let first = (json["elements"] as? [[String: Any]])?.first,
              let id = first["id"] else { return nil }
        let name = first["localizedName"] as? String ?? vanityName
        return Organization(urn: "urn:li:organization:\(id)", name: name)
    }

    // MARK: Plumbing

    private func rest(_ method: String, _ path: String, json: Any? = nil) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: URL(string: "https://api.linkedin.com/rest/\(path)")!)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "Linkedin-Version")
        request.setValue("2.0.0", forHTTPHeaderField: "X-Restli-Protocol-Version")
        if let json {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        return try await Self.send(request)
    }

    private static func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LinkedInError.message("No response from LinkedIn.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw LinkedInError.http(status: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }
        return (data, http)
    }

    static func encode(_ urn: String) -> String {
        urn.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? urn
    }
}
