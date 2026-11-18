import Foundation
import Testing
@testable import AgentXKit

@Suite("Pull requests")
struct PullRequestTests {
    @Test func readsYoursAndReviewRequestsWithChecks() throws {
        let json = try JSONDecoder().decode(JSONValue.self, from: Data("""
        {"data": {
          "viewer": {"pullRequests": {"nodes": [
            {"title": "Add launcher search", "url": "https://github.com/me/agentx/pull/12", "number": 12, "isDraft": false,
             "updatedAt": "2026-11-18T10:00:00Z", "reviewDecision": "APPROVED", "repository": {"nameWithOwner": "me/agentx"},
             "commits": {"nodes": [{"commit": {"statusCheckRollup": {"state": "FAILURE"}}}]}},
            {"title": "Draft idea", "url": "https://github.com/me/agentx/pull/13", "number": 13, "isDraft": true,
             "repository": {"nameWithOwner": "me/agentx"}, "commits": {"nodes": [{"commit": {"statusCheckRollup": null}}]}}
          ]}},
          "search": {"nodes": [
            {"title": "Fix flaky test", "url": "https://github.com/team/api/pull/7", "number": 7, "isDraft": false,
             "author": {"login": "enda"}, "repository": {"nameWithOwner": "team/api"},
             "commits": {"nodes": [{"commit": {"statusCheckRollup": {"state": "PENDING"}}}]}},
            {}
          ]}
        }}
        """.utf8))
        let prs = GitHubParser.pullRequests(json)
        #expect(prs.mine.count == 2 && prs.toReview.count == 1, "an empty search node is skipped")
        #expect(prs.mine[0].checks == .failing && prs.mine[0].review == "APPROVED" && prs.mine[0].repoName == "agentx")
        #expect(prs.mine[1].checks == .none && prs.mine[1].isDraft)
        #expect(prs.toReview[0].checks == .pending && prs.toReview[0].author == "enda")
        #expect(prs.failing == 1)
    }
}
