import Foundation
import Testing
@testable import OpenScreensCore

@Suite struct EmbeddedTailnetRouteTests {
    private let status = try! JSONDecoder().decode(TailscaleLocalStatus.self, from: Data(#"""
        {
          "BackendState": "Running",
          "AuthURL": "",
          "CurrentTailnet": {"Name": "example.com", "MagicDNSEnabled": true},
          "Self": {"ID": "self", "HostName": "OpenScreens-iPhone",
                   "DNSName": "openscreens-iphone.tail1234.ts.net.",
                   "TailscaleIPs": ["100.64.0.1"]},
          "Peer": {
            "nodekey:a": {"ID": "a", "HostName": "Studio",
                          "DNSName": "studio.tail1234.ts.net.",
                          "TailscaleIPs": ["fd7a:115c:a1e0::2", "100.64.0.2"]}
          }
        }
        """#.utf8))

    @Test(arguments: [
        "studio.tail1234.ts.net", "studio.tail1234.ts.net.", "Studio.tail1234.ts.net",
        "studio", "100.64.0.2", "FD7A:115C:A1E0::2",
    ])
    func reachesAPeerByAnyOfItsNames(host: String) {
        #expect(EmbeddedTailnet.peerAddress(for: host, in: status) == "100.64.0.2")
    }

    @Test(arguments: ["", "openscreens-iphone", "100.64.0.1", "192.168.1.10", "studio.local"])
    func leavesEverythingElseAlone(host: String) {
        #expect(EmbeddedTailnet.peerAddress(for: host, in: status) == nil)
    }

    @Test func readsTheTailnetAndSignInAddress() {
        #expect(status.currentTailnet?.name == "example.com")
        #expect(status.authURL == "")
    }
}
