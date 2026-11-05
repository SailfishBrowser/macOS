import Foundation

// A public GitHub repository's open pull requests, newest first, read from the REST API without signing in.
struct GitHubPulls: LiveSource {
  let owner: String
  let repo: String

  // github.com/owner/repo, or its pulls page.
  init?(url: URL) {
    let parts = url.pathComponents.filter { $0 != "/" }
    guard url.host()?.lowercased() == "github.com", parts.count == 2 || parts.count == 3 && parts[2] == "pulls"
    else { return nil }
    owner = parts[0]
    repo = parts[1]
  }

  var name: String { "\(owner)/\(repo)" }

  func fetch() async throws -> LiveFeed {
    var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(owner)/\(repo)/pulls?state=open&per_page=100")!)
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
    // URLSession revalidates with the ETag GitHub sends, and an unchanged answer costs no request of the
    // 60 an hour GitHub allows without signing in.
    let (data, response) = try await URLSession.shared.data(for: request)
    let http = response as! HTTPURLResponse
    if [403, 429].contains(http.statusCode) {
      if let after = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init) {
        throw LiveSourceError.rateLimited(until: Date().addingTimeInterval(after))
      }
      if http.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0",
        let reset = http.value(forHTTPHeaderField: "X-RateLimit-Reset").flatMap(TimeInterval.init)
      {
        throw LiveSourceError.rateLimited(until: Date(timeIntervalSince1970: reset))
      }
    }
    guard (200..<300).contains(http.statusCode) else { throw LiveSourceError.status(http.statusCode) }
    let pulls = try JSONDecoder().decode([Pull].self, from: data)
    return LiveFeed(links: pulls.map { LiveLink(url: $0.url, title: $0.title) })
  }

  private struct Pull: Decodable {
    let url: URL
    let title: String

    enum CodingKeys: String, CodingKey {
      case url = "html_url", title
    }
  }
}
