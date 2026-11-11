import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let source = CGImageSourceCreateWithURL(root.appendingPathComponent("Sources/SoundboundKit/Resources/SoundboundMark.png") as CFURL, nil)!
let logo = CGImageSourceCreateImageAtIndex(source, 0, nil)!
for platform in ["iOS", "macOS"] {
 let folder = root.appendingPathComponent("Apps/\(platform)/Assets.xcassets/AppIcon.appiconset")
 try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
 var entries: [[String: Any]] = []
 let sizes: [(Int, String, String)] = platform == "iOS" ? [(1024,"1024x1024","1x")] : [(16,"16x16","1x"),(32,"16x16","2x"),(32,"32x32","1x"),(64,"32x32","2x"),(128,"128x128","1x"),(256,"128x128","2x"),(256,"256x256","1x"),(512,"256x256","2x"),(512,"512x512","1x"),(1024,"512x512","2x")]
 for (index, item) in sizes.enumerated() {
  let (n,size,scale) = item
  let context = CGContext(data:nil,width:n,height:n,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.noneSkipLast.rawValue)!
  context.setFillColor(CGColor(gray:1,alpha:1)); context.fill(CGRect(x:0,y:0,width:n,height:n))
  context.draw(logo,in:CGRect(x:0,y:Double(n)/6,width:Double(n),height:Double(n)*2/3))
  let file = "icon-\(index)-\(n).png"
  let destination = CGImageDestinationCreateWithURL(folder.appendingPathComponent(file) as CFURL, UTType.png.identifier as CFString, 1, nil)!
  CGImageDestinationAddImage(destination, context.makeImage()!, nil)
  CGImageDestinationFinalize(destination)
  var entry: [String:Any] = ["filename":file,"idiom": platform == "iOS" ? "universal" : "mac","size":size]
  if platform == "iOS" { entry["platform"] = "ios" } else { entry["scale"] = scale }
  entries.append(entry)
 }
 try JSONSerialization.data(withJSONObject:["images":entries,"info":["author":"xcode","version":1]], options:.prettyPrinted).write(to:folder.appendingPathComponent("Contents.json"))
}
