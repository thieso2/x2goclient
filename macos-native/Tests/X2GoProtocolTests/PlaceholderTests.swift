import XCTest
@testable import X2GoProtocol

final class X2GoProtocolTests: XCTestCase {

    func testGeometryResolve() {
        let screen = Geometry(width: 1710, height: 1068)
        XCTAssertEqual(resolveGeometry(.fullscreen, screen: screen).geometry, screen)
        XCTAssertTrue(resolveGeometry(.fullscreen, screen: screen).wantFullscreen)
        XCTAssertEqual(resolveGeometry(.maxAvailable, screen: screen).geometry, screen)
        XCTAssertFalse(resolveGeometry(.maxAvailable, screen: screen).wantFullscreen)
        let big = resolveGeometry(.custom(width: 2560, height: 1440), screen: screen)
        XCTAssertEqual(big.geometry, Geometry(width: 2560, height: 1440))
        XCTAssertFalse(big.wantFullscreen)
        // out-of-range custom falls back
        XCTAssertEqual(resolveGeometry(.custom(width: 0, height: 0), screen: screen).geometry,
                       Geometry(width: 1280, height: 800))
    }

    func testStartAgentMatchesQtFormat() {
        let p = X2GoCommand.StartAgentParams(
            geometry: "1280x800", link: .lan, pack: "16m-jpeg-9", depth: 24,
            layout: "us", kbdType: "query", useKeyboard: false, kind: .desktop,
            command: "startxfce4", clipboard: .both)
        XCTAssertEqual(
            X2GoCommand.startAgent(p),
            "x2gostartagent 1280x800 lan 16m-jpeg-9 unix-kde-depth_24 us query 0 D startxfce4 both")
    }

    func testStartAgentDPIPrefix() {
        let p = X2GoCommand.StartAgentParams(geometry: "fullscreen", command: "startxfce4", dpi: 144)
        XCTAssertTrue(X2GoCommand.startAgent(p).hasPrefix("X2GODPI=144 x2gostartagent fullscreen "))
    }

    func testResumeAndRunAndLifecycle() {
        XCTAssertEqual(
            X2GoCommand.resumeSession(id: "sess-1", geometry: "1280x800", link: .lan,
                pack: "16m-jpeg-9", layout: "us", kbdType: "query", useKeyboard: false,
                clipboard: .both),
            "x2goresume-session sess-1 1280x800 lan 16m-jpeg-9 us query 0 both")
        XCTAssertEqual(
            X2GoCommand.runCommand(display: "213", agentPid: "1299079", sessionId: "sess-1",
                sndPort: "-1", command: "startxfce4", kind: .desktop),
            "setsid x2goruncommand 213 1299079 sess-1 -1 startxfce4 nosnd D 1> /dev/null 2>/dev/null & exit")
        XCTAssertEqual(X2GoCommand.suspend(id: "sess-1"), "x2gosuspend-session sess-1")
        XCTAssertEqual(X2GoCommand.terminate(id: "sess-1"), "x2goterminate-session sess-1")
    }

    func testNXOptionsAndArgs() {
        XCTAssertEqual(
            NXProxy.optionsFile(nxRoot: "/home/u/.x2go", sessionDir: "/home/u/.x2go/S-abc",
                cookie: "COOKIE", localPort: 33123, display: "213"),
            "nx/nx,root=/home/u/.x2go,connect=localhost,cookie=COOKIE,port=33123,errors=/home/u/.x2go/S-abc/sessions:213")
        XCTAssertEqual(
            NXProxy.args(sessionDir: "/home/u/.x2go/S-abc", display: "213"),
            ["-S", "nx/nx,options=/home/u/.x2go/S-abc/options:213"])
    }

    /// The real row captured from the live server via x2go-probe.
    func testParseRealSessionRow() {
        let line = "1299079|thies-213-1780579588_stDstartxfce4_dp24|213|dev.io.thieso2|S|2026-06-04T13:26:28|f85f618ff9736458615ec08e9435e082|10.248.1.2|45090|45091|2026-06-04T13:39:59|thies|4628|45092|-1|-1"
        let s = X2GoParser.sessionRow(line)
        XCTAssertNotNil(s)
        XCTAssertEqual(s?.agentPid, "1299079")
        XCTAssertEqual(s?.sessionId, "thies-213-1780579588_stDstartxfce4_dp24")
        XCTAssertEqual(s?.displayNumber, 213)
        XCTAssertEqual(s?.status, "S")
        XCTAssertTrue(s?.isSuspended ?? false)
        XCTAssertEqual(s?.cookie, "f85f618ff9736458615ec08e9435e082")
        XCTAssertEqual(s?.grPortNumber, 45090)
        XCTAssertEqual(s?.sndPort, "45091")
        XCTAssertEqual(s?.fsPort, "45092")
    }

    func testParseListSkipsGarbage() {
        let out = "warning: perl blah\n1299079|sess|213|host|S|t|cookie|ip|45090|45091\n"
        let rows = X2GoParser.sessionList(out)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.sessionId, "sess")
    }

    func testParseNewSessionReply() {
        let r = X2GoParser.newSessionReply("99\nF01CAFE\n4242\nthies-99-foo_stDstartxfce4_dp24\n45090\n45091\n45092\n")
        XCTAssertEqual(r?.displayNumber, 99)
        XCTAssertEqual(r?.cookie, "F01CAFE")
        XCTAssertEqual(r?.agentPid, "4242")
        XCTAssertEqual(r?.grPortNumber, 45090)
        XCTAssertEqual(r?.fsPort, "45092")
    }

    func testParseResumeReply() {
        let r = X2GoParser.resumeReply("gr_port=45090\nsound_port=45091\nfs_port=45092\n")
        XCTAssertEqual(r.grPort, "45090")
        XCTAssertEqual(r.sndPort, "45091")
        XCTAssertEqual(r.fsPort, "45092")
    }
}
