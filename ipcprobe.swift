import Foundation
// Ask Glotty for its provider list exactly the way the Reader does, and report
// whether a reply comes back and how big it is.
let nc = DistributedNotificationCenter.default()
let req = Notification.Name("com.ruojunye.glotty.reader.providers.request")
let rep = Notification.Name("com.ruojunye.glotty.reader.providers.reply")
var got = false
nc.addObserver(forName: rep, object: nil, queue: .main) { n in
    got = true
    let json = (n.userInfo?["providers"] as? String) ?? ""
    print("REPLY received: \(json.count) chars")
    if json.isEmpty { print("  (empty payload — userInfo value dropped?)") }
    else { print("  first 120: \(json.prefix(120))") }
    exit(0)
}
nc.postNotificationName(req, object: nil, userInfo: [:], deliverImmediately: true)
print("request posted, waiting 4s…")
RunLoop.main.run(until: Date().addingTimeInterval(4))
if !got { print("NO REPLY — Glotty never answered") }
exit(got ? 0 : 1)
