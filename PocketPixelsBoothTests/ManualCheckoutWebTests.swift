import XCTest
import WebKit
@testable import PocketPixelsBooth

/// Browser rendering/interaction checks against the exact generated Worker page. No external
/// account, money, receipt, or production endpoint is used. WebKit is Mobile Safari's engine.
@MainActor final class ManualCheckoutWebTests: XCTestCase {
    private let fixtureRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("DerivedData/payment-fixtures")
    private func browser(width: CGFloat, policy: String = "OPTIONAL", invalidLink: Bool = false) async throws -> (WKWebView, UIWindow) {
        let config=WKWebViewConfiguration()
        let mock="""
        window.original={id:'11111111-1111-4111-8111-111111111111',snapshotHash:'original-frozen-hash',copies:3,totalCentavos:7500,receiptPolicy:'\(policy)',receiver:{provider:'Synthetic test only',recipient:'Example recipient',identifier:'TEST-ONLY-LONG-IDENTIFIER-1234567890',instructions:'Do not send money. Synthetic browser test.'},receipt:null,acknowledgedAt:null,closedAt:null,expiresAt:new Date(Date.now()+1800000).toISOString()};
        window.requests=[];window.offline=false;window.uploads=0;window.loseUpload=true;
        window.fetch=async(path,options)=>{requests.push({path,body:JSON.parse(options.body),authorization:options.headers.authorization});if(offline)throw Error('Connection interrupted. Do not pay again.');if(path.endsWith('acknowledgments'))original.acknowledgedAt=new Date().toISOString();return {ok:true,json:async()=>JSON.parse(JSON.stringify(original))};};
        window.XMLHttpRequest=class {constructor(){this.upload={};}open(){}setRequestHeader(){}send(body){uploads++;window.lastUpload=JSON.parse(body);setTimeout(()=>{this.upload.onprogress?.({lengthComputable:true,loaded:1,total:1});original.receipt={submitted:true};if(loseUpload){loseUpload=false;this.ontimeout();}else{this.status=200;this.responseText='{"submitted":true}';this.onload();}},30);}};
        """
        config.userContentController.addUserScript(WKUserScript(source:mock,injectionTime:.atDocumentStart,forMainFrameOnly:true))
        let web=WKWebView(frame:CGRect(x:0,y:0,width:width,height:844),configuration:config)
        let controller=UIViewController();controller.view=web
        let window=UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first.map(UIWindow.init(windowScene:)) ?? UIWindow(frame:web.frame)
        window.frame=web.frame;window.rootViewController=controller;window.makeKeyAndVisible();controller.view.layoutIfNeeded()
        let html=try String(contentsOf:fixtureRoot.appendingPathComponent("checkout.html"),encoding:.utf8)
        let fragment=invalidLink ? "" : "#c=11111111-1111-4111-8111-111111111111."+String(repeating:"a",count:64)
        web.loadHTMLString(html,baseURL:URL(string:"https://synthetic.example.test/checkout?fixture=\(UUID())"+fragment))
        try await wait(web,"document.readyState==='complete' && document.getElementById('notice').textContent !== 'Opening your original checkout…'")
        return (web,window)
    }
    private func wait(_ web: WKWebView,_ condition: String) async throws {
        let deadline=ContinuousClock.now.advanced(by:.seconds(15))
        while ContinuousClock.now < deadline {
            if (try? await web.evaluateJavaScript(condition) as? Bool)==true{return}
            try await Task.sleep(for:.milliseconds(40))
        }
        XCTFail("Browser state did not settle: \(condition)")
        throw SetupFailure("Browser test timeout")
    }
    private func expect<T: Equatable>(_ web: WKWebView, _ expression: String, _ expected: T, file: StaticString = #filePath, line: UInt = #line) async throws {
        let result = try await web.evaluateJavaScript(expression) as? T
        XCTAssertEqual(result, expected, file: file, line: line)
    }
    func testRepresentativeMobileWidthsHaveReadableCardsAndFullSizeActions() async throws {
        for width: CGFloat in [320,375,430] {
            let (web,window)=try await browser(width:width);defer{window.isHidden=true}
            let valid=try await web.evaluateJavaScript("document.documentElement.scrollWidth<=innerWidth && document.getElementById('amount').textContent.includes('75.00') && document.getElementById('quantity').textContent.includes('3 identical') && [...document.querySelectorAll('button:not([hidden])')].filter(b=>b.getBoundingClientRect().height>0).every(b=>b.getBoundingClientRect().height>=44)") as? Bool
            XCTAssertEqual(valid,true,"Viewport \(width)")
            let snapshot=try await web.takeSnapshot(configuration:nil)
            try snapshot.pngData()?.write(to:fixtureRoot.appendingPathComponent("layout-\(Int(width)).png"))
        }
    }
    func testEveryPolicyAcknowledgesTheOriginalSnapshotWithoutEquatingReceiptWithFunds() async throws {
        for policy in ["ACK_ONLY","OPTIONAL","REQUIRED"] {
            let(web,window)=try await browser(width:375,policy:policy);defer{window.isHidden=true}
            let hidden=try await web.evaluateJavaScript("document.getElementById('evidence').hidden") as? Bool;XCTAssertEqual(hidden,policy=="ACK_ONLY")
            _ = try await web.evaluateJavaScript("document.getElementById('transferred').checked=true;document.getElementById('transferred').dispatchEvent(new Event('change'));document.getElementById('ack').click();true")
            try await wait(web,"document.getElementById('notice').textContent.includes('Acknowledgment saved')")
            try await expect(web,"requests.at(-1).body.snapshotHash","original-frozen-hash")
            try await expect(web,"document.getElementById('receiving-details').hidden",true)
            if policy=="REQUIRED" {try await expect(web,"document.getElementById('notice').textContent.includes('Submit your receipt')",true)}
            else {try await expect(web,"document.getElementById('notice').textContent.includes('not been independently verified')",true)}
        }
    }
    func testSelectedImagePreviewAndLostUploadConfirmationRecoverThroughOriginalStatus() async throws {
        let(web,window)=try await browser(width:375,policy:"REQUIRED");defer{window.isHidden=true}
        _ = try await web.evaluateJavaScript("""
        const bytes=Uint8Array.from(atob('iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAEElEQVR4nGNoUDAAIgYIBQAYDgNB5YZ+PAAAAABJRU5ErkJggg=='),c=>c.charCodeAt(0));const dt=new DataTransfer();dt.items.add(new File([bytes],'synthetic.png',{type:'image/png'}));document.getElementById('file').files=dt.files;document.getElementById('file').dispatchEvent(new Event('change'));true
        """)
        try await wait(web,"!document.getElementById('preview').hidden && !document.getElementById('upload').disabled")
        _ = try await web.evaluateJavaScript("document.getElementById('upload').click();document.getElementById('upload').click();true")
        try await wait(web,"document.getElementById('notice').textContent.includes('interrupted')")
        try await expect(web,"uploads",1)
        try await expect(web,"lastUpload.snapshotHash","original-frozen-hash")
        _ = try await web.evaluateJavaScript("document.getElementById('retry').click();true")
        try await wait(web,"document.getElementById('receiptState').textContent==='Receipt stored privately.'")
        try await expect(web,"uploads",1)
    }
    func testInvalidLinkAndOfflineStatusAreRecoverableWithoutAskingForAnotherPayment() async throws {
        let(web,window)=try await browser(width:320,invalidLink:true);defer{window.isHidden=true}
        try await expect(web,"requests.length",0)
        try await expect(web,"document.getElementById('notice').textContent.includes('Scan the checkout QR')",true)
        let(other,otherWindow)=try await browser(width:430);defer{otherWindow.isHidden=true}
        _ = try await other.evaluateJavaScript("offline=true;document.getElementById('retry').click();true")
        try await wait(other,"document.getElementById('notice').textContent.includes('Do not pay again') && !document.getElementById('retry').disabled")
    }
}
