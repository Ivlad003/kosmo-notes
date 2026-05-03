import Foundation

// MARK: - S3Client

/// Tiny S3-compatible client. Implements just enough of the S3 REST API for
/// upload + presigned GET. Compatible with AWS S3, Cloudflare R2 (region: auto),
/// Backblaze B2, MinIO, RustFS — anything that speaks S3 + Sig V4.
public struct S3Client: Sendable {

    public typealias HTTPClient = @Sendable (URLRequest, Data?) async throws -> (Data, URLResponse)

    public let endpoint: URL          // e.g. https://s3.amazonaws.com or https://<account>.r2.cloudflarestorage.com
    public let region: String         // e.g. us-east-1 / auto
    public let bucket: String
    public let credentials: SigV4.Credentials
    public let httpClient: HTTPClient

    public init(
        endpoint: URL,
        region: String,
        bucket: String,
        credentials: SigV4.Credentials,
        httpClient: @escaping HTTPClient = S3Client.defaultHTTPClient
    ) {
        self.endpoint = endpoint
        self.region = region
        self.bucket = bucket
        self.credentials = credentials
        self.httpClient = httpClient
    }

    public static let defaultHTTPClient: HTTPClient = { request, body in
        var req = request
        if let body {
            return try await URLSession.shared.upload(for: req, from: body)
        }
        // GET / HEAD: no body.
        req.httpBody = nil
        return try await URLSession.shared.data(for: req)
    }

    /// Build the URL for a key under this bucket. Uses path-style addressing
    /// (https://endpoint/bucket/key) which works across all S3-compatibles.
    public func objectURL(key: String) -> URL {
        endpoint
            .appendingPathComponent(bucket, isDirectory: true)
            .appendingPathComponent(key)
    }

    // MARK: - PutObject

    /// Upload `data` to `key` with optional content-type. Returns the object URL.
    /// Signed via Sig V4 in the Authorization header. Synchronous body — large
    /// uploads should pre-chunk before calling.
    @discardableResult
    public func putObject(
        key: String,
        data: Data,
        contentType: String = "application/octet-stream",
        now: Date = Date()
    ) async throws -> URL {
        let url = objectURL(key: key)
        guard let host = url.host else { throw S3Error.invalidEndpoint }

        let amzDate = SigV4.amzDateTime(now)
        let payloadHash = SigV4.sha256Hex(data)

        var headers: [String: String] = [
            "host": host,
            "x-amz-date": amzDate,
            "x-amz-content-sha256": payloadHash,
            "content-type": contentType,
            "content-length": "\(data.count)",
        ]

        let path = url.path  // already includes /bucket/key
        let canonical = SigV4.canonicalize(
            method: "PUT",
            path: path,
            query: [],
            headers: headers,
            payloadHash: payloadHash
        )
        let toSign = SigV4.stringToSign(
            date: now,
            region: region,
            service: "s3",
            canonicalRequest: canonical
        )
        let sig = SigV4.signature(
            stringToSign: toSign,
            secret: credentials.secretAccessKey,
            date: now,
            region: region,
            service: "s3"
        )
        let scope = "\(SigV4.amzDateOnly(now))/\(region)/s3/aws4_request"
        let auth = "AWS4-HMAC-SHA256 Credential=\(credentials.accessKeyId)/\(scope), SignedHeaders=\(canonical.signedHeaders), Signature=\(sig)"
        headers["authorization"] = auth

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        for (k, v) in headers {
            request.setValue(v, forHTTPHeaderField: k)
        }

        let (responseData, response) = try await httpClient(request, data)
        guard let http = response as? HTTPURLResponse else { throw S3Error.nonHTTPResponse }
        if !(200..<300).contains(http.statusCode) {
            let body = String(data: responseData, encoding: .utf8) ?? "<unreadable>"
            throw S3Error.httpStatus(http.statusCode, body)
        }
        return url
    }

    // MARK: - Presigned GET

    /// Build a presigned GET URL. `expirySeconds` is clamped to 7 days (S3 max).
    public func presignedGetURL(
        key: String,
        expirySeconds: Int,
        now: Date = Date()
    ) throws -> URL {
        let url = objectURL(key: key)
        guard let host = url.host else { throw S3Error.invalidEndpoint }

        // Sig V4 max expiry is 7 days (604800s).
        let clampedExpiry = max(1, min(expirySeconds, 604_800))

        let amzDate = SigV4.amzDateTime(now)
        let scope = "\(SigV4.amzDateOnly(now))/\(region)/s3/aws4_request"

        // Headers signed in the canonical request: only `host`.
        let signedHeaders = "host"
        let headers: [String: String] = ["host": host]

        // Query parameters that are part of the signature.
        let baseQuery: [(String, String)] = [
            ("X-Amz-Algorithm", "AWS4-HMAC-SHA256"),
            ("X-Amz-Credential", "\(credentials.accessKeyId)/\(scope)"),
            ("X-Amz-Date", amzDate),
            ("X-Amz-Expires", "\(clampedExpiry)"),
            ("X-Amz-SignedHeaders", signedHeaders),
        ]

        let canonical = SigV4.canonicalize(
            method: "GET",
            path: url.path,
            query: baseQuery,
            headers: headers,
            payloadHash: SigV4.unsignedPayload
        )
        let toSign = SigV4.stringToSign(
            date: now,
            region: region,
            service: "s3",
            canonicalRequest: canonical
        )
        let sig = SigV4.signature(
            stringToSign: toSign,
            secret: credentials.secretAccessKey,
            date: now,
            region: region,
            service: "s3"
        )

        // Append the signed query params + the signature in the right order.
        var allQuery = baseQuery
        allQuery.append(("X-Amz-Signature", sig))

        let encodedPairs = allQuery.map { pair -> String in
            let k = SigV4.awsEncode(pair.0, encodeSlash: true)
            let v = SigV4.awsEncode(pair.1, encodeSlash: true)
            return k + "=" + v
        }
        let queryString = encodedPairs.joined(separator: "&")

        guard let presigned = URL(string: "\(url.absoluteString)?\(queryString)") else {
            throw S3Error.invalidEndpoint
        }
        return presigned
    }
}

// MARK: - Errors

public enum S3Error: Error, LocalizedError {
    case invalidEndpoint
    case nonHTTPResponse
    case httpStatus(Int, String)

    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint: return "Invalid S3 endpoint."
        case .nonHTTPResponse: return "Non-HTTP response from S3."
        case .httpStatus(let code, let body): return "S3 returned HTTP \(code): \(body)"
        }
    }
}
