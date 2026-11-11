import AppKit
import WebKit
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
final class Probe: NSObject, WKNavigationDelegate {
 let web: WKWebView
 let window: NSWindow
 let output: String
 init(url: String, output: String) {
  self.output = output
  let config = WKWebViewConfiguration()
  let script = """
  window.probe={firstPhotoMs:null,allPhotosMs:null,maxHeartbeatGapMs:0};
  let last=performance.now();setInterval(()=>{const n=performance.now();probe.maxHeartbeatGapMs=Math.max(probe.maxHeartbeatGapMs,n-last);last=n;},20);
  const tick=()=>{
   const imgs=[...document.querySelectorAll('[data-collage],.shot img')];
   const visible=imgs.filter(i=>{const r=i.getBoundingClientRect();return i.complete&&i.naturalWidth>0&&!i.hidden&&r.width>0&&r.height>0&&r.bottom>0&&r.top<innerHeight;});
   if(visible.length&&probe.firstPhotoMs===null)probe.firstPhotoMs=performance.now();
   const photos=[...document.querySelectorAll('.shot img')];
   if(photos.length&&photos.every(i=>i.complete&&i.naturalWidth>0&&!i.hidden)&&probe.allPhotosMs===null)probe.allPhotosMs=performance.now();
   const first=document.querySelector('.shot [data-download]'),all=document.getElementById('shareAll');
   if(typeof photoItems!=='undefined'&&!probe.galleryActionsMs)probe.galleryActionsMs=performance.now();
   if(first&&!first.disabled&&probe.firstPhotoMs&&!probe.firstPhotoActionsMs)probe.firstPhotoActionsMs=performance.now();
   if(all&&!all.disabled&&typeof photoItems!=='undefined'&&!probe.downloadAllActionsMs)probe.downloadAllActionsMs=performance.now();
   const receipts=[...document.querySelectorAll('.receipt-card img')];
   if(receipts.length&&receipts.every(i=>i.complete&&i.naturalWidth>0&&!i.hidden)&&!probe.receiptsMs)probe.receiptsMs=performance.now();
   requestAnimationFrame(tick);
  };requestAnimationFrame(tick);
  for(const type of ['paint','largest-contentful-paint','longtask']){try{new PerformanceObserver(list=>{for(const e of list.getEntries()){if(type==='paint')probe[e.name]=e.startTime;if(type==='largest-contentful-paint')probe.lcpMs=e.startTime;if(type==='longtask')probe.longTaskMs=(probe.longTaskMs||0)+e.duration;}}).observe({type,buffered:true});}catch(e){}}
  """
  config.userContentController.addUserScript(WKUserScript(source:script,injectionTime:.atDocumentStart,forMainFrameOnly:true))
  web = WKWebView(frame:NSRect(x:0,y:0,width:390,height:844),configuration:config)
  window = NSWindow(contentRect:NSRect(x:0,y:0,width:390,height:844),styleMask:[.titled],backing:.buffered,defer:false)
  super.init();window.contentView=web;window.orderFrontRegardless();web.navigationDelegate=self
  web.load(URLRequest(url:URL(string:url)!))
  DispatchQueue.main.asyncAfter(deadline:.now()+80){self.finish(error:"timeout")}
 }
 func webView(_ webView:WKWebView,didFinish navigation:WKNavigation!){poll()}
 func poll(){web.evaluateJavaScript("JSON.stringify({...probe,ready:!!probe.allPhotosMs, navigation:performance.getEntriesByType('navigation').map(n=>({ttfbMs:n.responseStart,domContentLoadedMs:n.domContentLoadedEventEnd,loadMs:n.loadEventEnd,encodedBytes:n.encodedBodySize,decodedBytes:n.decodedBodySize})),supportedEntries:PerformanceObserver.supportedEntryTypes||[],heapBytes:performance.memory?.usedJSHeapSize||null,images:[...document.images].filter(i=>i.getAttribute('src')).length,conversions:typeof realFileCache==='undefined'?null:realFileCache.size})"){v,e in
  if let s=v as? String, let data=s.data(using:.utf8), let d=try? JSONSerialization.jsonObject(with:data) as? [String:Any],d["ready"] as? Bool == true {DispatchQueue.main.asyncAfter(deadline:.now()+0.2){self.finish(error:nil)}}else{DispatchQueue.main.asyncAfter(deadline:.now()+0.05){self.poll()}}
 }}
 var finished=false
 func finish(error:String?){if finished{return};finished=true
  web.evaluateJavaScript("JSON.stringify({...probe,navigation:performance.getEntriesByType('navigation').map(n=>({ttfbMs:n.responseStart,domContentLoadedMs:n.domContentLoadedEventEnd,loadMs:n.loadEventEnd,encodedBytes:n.encodedBodySize,decodedBytes:n.decodedBodySize})),supportedEntries:PerformanceObserver.supportedEntryTypes||[],heapBytes:performance.memory?.usedJSHeapSize||null,conversions:typeof realFileCache==='undefined'?null:realFileCache.size})"){v,e in
   var d=(v as? String).flatMap{$0.data(using:.utf8)}.flatMap{try? JSONSerialization.jsonObject(with:$0) as? [String:Any]} ?? [:];if let error=error{d["error"]=error}
   if let data=try? JSONSerialization.data(withJSONObject:d,options:[.prettyPrinted,.sortedKeys]){try? data.write(to:URL(fileURLWithPath:self.output))};app.terminate(nil)
  }
 }
}
let probe=Probe(url:CommandLine.arguments[1],output:CommandLine.arguments[2]);app.run()
