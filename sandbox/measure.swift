import AppKit
let a = CommandLine.arguments
let f = NSFont(name: a[1], size: CGFloat(Double(a[2])!))!
for s in a[3...] {
  let r = (s as NSString).boundingRect(with: NSSize(width: 10000, height: 10000), options: [.usesLineFragmentOrigin], attributes: [.font: f])
  print(s, r.width, r.height)
}
