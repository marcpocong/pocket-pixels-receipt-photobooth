// Installed temporarily into the synchronized test target by run-network-benchmarks.py.
// Real loopback TCP bytes are paced by the host fixture; Google latency is not modeled.
import Darwin
import Foundation
import UIKit
import XCTest
@testable import PocketPixelsBooth

@MainActor final class ManualBacklogBenchmarks: XCTestCase {
    func testDurableRecoveryOverPacedTCP() async throws {
        executionTimeAllowance = 1800
        let repo = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent()
        let output = repo.appendingPathComponent("DerivedData/gallery-network-results.json")
        let config = try JSONSerialization.jsonObject(with:Data(contentsOf:repo.appendingPathComponent("DerivedData/gallery-network-config.json"))) as! [String:Any]
        let base = URL(string:"http://127.0.0.1:\(config["port"] as! Int)")!
        VenueBridge.base = base
        let selected = config["profiles"] as? [String] ?? ["strong20","strong50","strong100","weak20","improved20","interrupted50"]
        let image = GalleryPipelineBenchmarkTests.photo(seed:1)
        let receipt = try ReceiptComposer.compose(photos:[image],sessionIdentifier:"PP-20261111-120000",date:Date(),format:.solo)
        let prepared = try GoogleDriveGalleryUploadService.preparePayload(photos:[image],composedReceipt:UIImage(data:receipt.imagePNGData)!,
            sessionID:"PP-20261111-120000",createdAt:Date(),galleryToken:String(repeating:"a",count:64),
            customerGalleryBaseURL:URL(string:"https://venue.synthetic.test/")!,
            receiptVariants:GalleryReceiptVariants(originalFooterStyle:.decorativeBarcodeOnly,defaultStyle:.shareFriendly))
        var rows:[[String:Any]] = []
        for name in selected {
            let scenario = name.replacingOccurrences(of: "adaptive-", with: "")
            let count = name.contains("100") ? 100 : name.contains("50") ? 50 : 20
            let preferences:[GalleryUploadTransportPreference] = name.hasPrefix("adaptive-") ? [.automatic] : scenario == "interrupted50" ? [.resumable] : [.legacy,.resumable]
            for preference in preferences {
                // Cost constraints are explicit fixture inputs; do not inherit
                // the host Mac's unrelated hotspot/VPN path classification.
                GalleryTransferTelemetry.shared.constrainedPath = false
                GalleryTransferTelemetry.shared.resetPathEstimate()
                let resumable = preference != .legacy
                let network:[String:Any] = ["mbps":scenario == "weak20" ? 0.5 : scenario == "improved20" ? 0.25 : 0,
                    "improveAfter":scenario == "improved20" ? 4 : 0,"loseChunkAck":scenario == "interrupted50"]
                var reset = URLRequest(url:base.appendingPathComponent("reset"));reset.httpMethod="POST"
                reset.httpBody=try JSONSerialization.data(withJSONObject:network)
                _ = try await URLSession.shared.data(for:reset)
                let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                defer { try? FileManager.default.removeItem(at:root) }
                let store = try GalleryPendingUploadStore(directoryURL:root)
                let proofs = try GalleryVerificationStore(directory:root.appendingPathComponent("proof"))
                var tokens:[String]=[]
                for index in 0..<count {
                    let token=String(format:"%064x",index+1);tokens.append(token)
                    let payload = GalleryPreparedUploadPayload(schemaVersion:4,galleryToken:token,
                        galleryURL:URL(string:"https://venue.synthetic.test/?g=\(token)")!,
                        sessionID:"PP-20261111-120000-\(UUID().uuidString.lowercased())",createdAt:GalleryUploadDateFormatter.string(from:Date(timeIntervalSince1970:Double(index))),
                        photos:prepared.photos,colorReceipt:prepared.colorReceipt,thermalReceipt:nil,gif:nil,metrics:prepared.metrics,
                        deliveryState:.notStarted,receiptVariants:prepared.receiptVariants)
                    try store.save(payload)
                }
                let configuration=URLSessionConfiguration.ephemeral;configuration.protocolClasses=[VenueBridge.self]
                configuration.timeoutIntervalForResource=1800
                var completions:[Double]=[]
                let began=ProcessInfo.processInfo.systemUptime
                let endpoint = resumable ? URL(string:"https://script.google.com/macros/s/VENUE-\(UUID().uuidString)/exec")! : base.appendingPathComponent("legacy")
                let service=GoogleDriveGalleryUploadService(transportPreference:preference,
                    configurationProvider:{GoogleDriveGalleryConfiguration(webAppURL:endpoint)},
                    urlSession:URLSession(configuration:configuration),pendingStore:store,verificationStore:proofs,
                    scheduler:GalleryUploadScheduler(),onPublicGalleryVerified:{_ in completions.append((ProcessInfo.processInfo.systemUptime-began)*1000)})
                var maxGap=0.0,peakMemory:UInt64=Self.memory(),last=ProcessInfo.processInfo.systemUptime
                let heartbeat=Task { @MainActor in
                    var n=0
                    while !Task.isCancelled {
                        do { try await Task.sleep(for:.milliseconds(16)) } catch { return }
                        let now=ProcessInfo.processInfo.systemUptime;maxGap=max(maxGap,(now-last)*1000);last=now;n+=1
                        if n%60 == 0 { peakMemory=max(peakMemory,Self.memory()) }
                    }
                }
                do { _ = try await service.retryPendingQueue(deviceToken:"synthetic-only-venue-fixture") }
                catch let error as GalleryPendingQueueFailure where scenario == "interrupted50" {
                    XCTAssertEqual(error.failedCount,1)
                    try store.requestRetry(connectivityRestored:true)
                    _ = try await service.retryPendingQueue(deviceToken:"synthetic-only-venue-fixture")
                }
                heartbeat.cancel()
                let total=(ProcessInfo.processInfo.systemUptime-began)*1000
                let (data,_)=try await URLSession.shared.data(from:base.appendingPathComponent("stats"))
                let stats=try JSONSerialization.jsonObject(with:data) as! [String:Any]
                XCTAssertEqual(stats["publications"] as? Int,count)
                XCTAssertEqual(stats["duplicatePublications"] as? Int,0)
                XCTAssertTrue(try store.summaries().isEmpty)
                XCTAssertEqual(completions.count,count)
                if name == "adaptive-strong100" {
                    XCTAssertLessThan(stats["controlBodyBytesRead"] as! Int,count*1000,
                        "A measured fast path must not initialize every fresh gallery as resumable")
                }
                if preference == .resumable {
                    XCTAssertEqual((stats["actualBodyBytesRead"] as! Int)-(stats["controlBodyBytesRead"] as! Int),count*prepared.metrics.totalDecodedBytes,
                        "Even a lost chunk ACK must not retransmit confirmed media")
                }
                let row:[String:Any]=["profile":name,"transport":preference == .automatic ? "automatic" : resumable ? "binary-resumable" : "legacy-json",
                    "guests":count,"decodedMediaBytes":count*prepared.metrics.totalDecodedBytes,"firstReadyMs":completions.first ?? 0,
                    "totalMs":total,"completionMs":GalleryPipelineBenchmarkTests.stats(completions),"origin":stats,
                    "maxMainActorGapMs":maxGap,"peakResidentBytes":peakMemory,
                    "effectiveBytesPerSecond":GalleryTransferTelemetry.shared.recentBytesPerSecond,
                    "constrainedPath":GalleryTransferTelemetry.shared.constrainedPath]
                rows.append(row)
                print("GALLERY_VENUE_BENCHMARK \(String(data:try JSONSerialization.data(withJSONObject:row,options:.sortedKeys),encoding:.utf8)!)")
                try JSONSerialization.data(withJSONObject:["environment":"iPad simulator; actual durable retryPendingQueue and byte payloads; real loopback TCP with aggregate receive pacing; scoped-Google/public requests bridged to synthetic origin; not Google server timing or venue hardware", "rows":rows],options:[.prettyPrinted,.sortedKeys]).write(to:output,options:.atomic)
            }
        }
    }
    private static func memory() -> UInt64 {
        var info=mach_task_basic_info(),count=mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size/MemoryLayout<integer_t>.size)
        let result=withUnsafeMutablePointer(to:&info){$0.withMemoryRebound(to:integer_t.self,capacity:Int(count)){task_info(mach_task_self_,task_flavor_t(MACH_TASK_BASIC_INFO),$0,&count)}}
        return result == KERN_SUCCESS ? info.resident_size : 0
    }
}

private nonisolated final class VenueBridge:URLProtocol,@unchecked Sendable {
    nonisolated(unsafe) static var base:URL!
    private var forward:URLSessionDataTask?
    private var observer:GalleryTransferObserver?
    override class func canInit(with request:URLRequest)->Bool {
        ["script.google.com","www.googleapis.com","venue.synthetic.test"].contains(request.url?.host ?? "")
    }
    override class func canonicalRequest(for request:URLRequest)->URLRequest { request }
    override func startLoading() {
        var body=request.httpBody ?? Data()
        if body.isEmpty,let stream=request.httpBodyStream {
            stream.open();defer{stream.close()};var buffer=[UInt8](repeating:0,count:65536)
            while true {let n=stream.read(&buffer,maxLength:buffer.count);if n<=0{break};body.append(contentsOf:buffer.prefix(n))}
        }
        let original=URLComponents(url:request.url!,resolvingAgainstBaseURL:false)!
        let path:String
        if request.url!.host == "venue.synthetic.test" {path="status"}
        else if request.url!.host == "www.googleapis.com" {path="upload"}
        else if request.httpMethod == "GET" {path="diagnostic"}
        else {
            let json=(try? JSONSerialization.jsonObject(with:body)) as? [String:Any]
            path=json?["transport"] as? String == "drive-resumable-v1" ? "coordinate" : "legacy"
        }
        var local=URLComponents(url:Self.base.appendingPathComponent(path),resolvingAgainstBaseURL:false)!
        local.queryItems=original.queryItems
        var outgoing=request;outgoing.url=local.url;outgoing.cachePolicy = .reloadIgnoringLocalCacheData
        outgoing.httpBodyStream=nil;outgoing.httpBody=body.isEmpty ? nil : body
        forward=URLSession.shared.dataTask(with:outgoing){[self] data,response,error in
            observer?.finish(succeeded:error == nil)
            if let error {client?.urlProtocol(self,didFailWithError:error);return}
            guard let response=response as? HTTPURLResponse else {client?.urlProtocol(self,didFailWithError:URLError(.badServerResponse));return}
            let headers=response.allHeaderFields.reduce(into:[String:String]()){$0[String(describing:$1.key)]=String(describing:$1.value)}
            client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:response.statusCode,httpVersion:nil,headerFields:headers)!,cacheStoragePolicy:.notAllowed)
            client?.urlProtocol(self,didLoad:data ?? Data());client?.urlProtocolDidFinishLoading(self)
        }
        if request.httpMethod == "PUT",!body.isEmpty,let forward {
            // Observe the actual forwarded TCP request (the outer URLProtocol
            // task alone only sees buffered fixture bytes).
            let measurement=GalleryTransferObserver();observer=measurement;forward.delegate=measurement
            measurement.start(forward,expected:Int64(body.count))
        }
        forward?.resume()
    }
    override func stopLoading(){forward?.cancel()}
}
