import AppKit
import AVFoundation
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// One preview frame and where it came from.
struct Preview: Identifiable {
    var name: String
    var date: Date?
    var image: NSImage
    var id: String { name }
}

/// Thumbnails for cards in the QNAP's readers and sources on this Mac, using as little data as possible:
/// Sony's own thumbnails, the JPEG previews inside photos, and only the parts of a video macOS needs to decode one frame.
enum Previews {
    static let videoTypes: Set<String> = ["mp4", "mov", "mxf", "mts", "m2ts", "insv", "avi"]
    static let photoTypes: Set<String> = ["arw", "cr3", "cr2", "nef", "raf", "dng", "rw2", "orf", "jpg", "jpeg", "heic", "heif", "hif", "tif", "tiff", "insp"]

    /// Up to `count` files spread across the card's timeline, videos first.
    static func sample<T>(_ files: [T], count: Int, name: (T) -> String, time: (T) -> Int64) -> [T] {
        let exts = files.map { (name($0) as NSString).pathExtension.lowercased() }
        let videos = zip(files, exts).filter { videoTypes.contains($0.1) }.map(\.0)
        let photos = zip(files, exts).filter { photoTypes.contains($0.1) }.map(\.0)
        let pool = (videos.count >= count || photos.isEmpty ? videos : videos + photos).sorted { time($0) < time($1) }
        guard pool.count > count else { return pool }
        return (0..<count).map { pool[Int(Double($0) * Double(pool.count - 1) / Double(count - 1))] }
    }

    // MARK: Cards on the QNAP

    static func card(_ c: Card, count: Int = 6) async -> [Preview] {
        let picks = sample(c.media, count: count, name: \.name, time: \.mtime)
        var out: [Preview] = []
        for f in picks {
            let date = Date(timeIntervalSince1970: TimeInterval(f.mtime))
            if let img = await remoteImage(c, f) { out.append(Preview(name: f.name, date: date, image: img)) }
        }
        return out
    }

    private static func remoteImage(_ c: Card, _ f: CardFile) async -> NSImage? {
        let t = NAS.target(.qnap)
        let path = c.mount + "/" + f.path
        let ext = (f.name as NSString).pathExtension.lowercased()
        if videoTypes.contains(ext) {
            // Sony keeps a thumbnail per clip: CLIP/FX3_9913.MP4 -> THMBNL/FX3_9913T01.JPG
            if f.path.contains("M4ROOT/CLIP/") {
                let thumb = c.mount + "/" + f.path.replacingOccurrences(of: "/CLIP/", with: "/THMBNL/")
                    .replacingOccurrences(of: "." + (f.name as NSString).pathExtension, with: "T01.JPG")
                if let r = try? await SSH.run(t, "cat \(shq(thumb))"), r.code == 0, let img = NSImage(data: r.out) { return img }
            }
            return await RemoteVideo(target: t, path: path, size: f.size, ext: ext).frame()
        }
        // Photos (RAW and JPEG) carry small JPEG previews near the start of the file.
        guard let r = try? await SSH.run(t, "head -c 1500000 \(shq(path))"), r.code == 0 else { return nil }
        guard let img = embeddedJPEG(r.out) else { return nil }
        // RAW files keep the camera's rotation in their own header, not in the embedded preview.
        return rotated(img, orientation: tiffOrientation(r.out))
    }

    /// EXIF orientation (1-8) from the first IFD of a TIFF-based file (ARW, NEF, DNG, CR2...), if it's one.
    static func tiffOrientation(_ d: Data) -> Int {
        let b = [UInt8](d.prefix(65536))
        guard b.count > 16 else { return 1 }
        let little: Bool
        if b[0] == 0x49, b[1] == 0x49 { little = true } else if b[0] == 0x4D, b[1] == 0x4D { little = false } else { return 1 }
        func u16(_ o: Int) -> Int { o + 1 < b.count ? (little ? Int(b[o]) | Int(b[o + 1]) << 8 : Int(b[o]) << 8 | Int(b[o + 1])) : 0 }
        func u32(_ o: Int) -> Int { (little ? u16(o) | u16(o + 2) << 16 : u16(o) << 16 | u16(o + 2)) }
        let ifd = u32(4)
        guard ifd > 0, ifd + 2 < b.count else { return 1 }
        for i in 0..<u16(ifd) {
            let e = ifd + 2 + i * 12
            if e + 10 >= b.count { break }
            if u16(e) == 0x0112 { return max(1, min(8, u16(e + 8))) }
        }
        return 1
    }

    static func rotated(_ img: NSImage, orientation: Int) -> NSImage {
        let degrees: CGFloat
        switch orientation {
        case 3: degrees = 180
        case 6: degrees = -90
        case 8: degrees = 90
        default: return img
        }
        let s = img.size
        let out = degrees == 180 ? s : NSSize(width: s.height, height: s.width)
        return NSImage(size: out, flipped: false) { rect in
            let t = NSAffineTransform()
            t.translateX(by: rect.width / 2, yBy: rect.height / 2)
            t.rotate(byDegrees: degrees)
            t.translateX(by: -s.width / 2, yBy: -s.height / 2)
            t.concat()
            img.draw(in: NSRect(origin: .zero, size: s))
            return true
        }
    }

    /// The largest decodable JPEG found in the data (RAW and JPEG files embed previews and thumbnails).
    static func embeddedJPEG(_ data: Data) -> NSImage? {
        let bytes = [UInt8](data)
        var best: (NSImage, CGFloat)?
        var i = 0
        var tried = 0
        while i + 3 < bytes.count, tried < 12 {
            guard bytes[i] == 0xFF, bytes[i + 1] == 0xD8, bytes[i + 2] == 0xFF else { i += 1; continue }
            tried += 1
            if let src = CGImageSourceCreateWithData(data.subdata(in: i..<data.count) as CFData, nil),
               let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                     kCGImageSourceThumbnailMaxPixelSize: 480,
                                                                     kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) {
                let w = CGFloat(cg.width)
                if w > (best?.1 ?? 0) { best = (NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)), w) }
                if w >= 320 { break }
            }
            i += 3
        }
        return best?.0
    }

    // MARK: Sources on this Mac

    static func local(_ s: AudioSource, count: Int = 6) async -> [Preview] {
        let picks = sample(s.files, count: count, name: \.name, time: { f in
            Int64((try? f.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate?.timeIntervalSince1970) ?? 0)
        })
        var out: [Preview] = []
        for f in picks {
            let req = QLThumbnailGenerator.Request(fileAt: f.url, size: CGSize(width: 240, height: 160), scale: 2, representationTypes: .thumbnail)
            if let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: req) {
                out.append(Preview(name: f.name, date: nil, image: rep.nsImage))
            } else if videoTypes.contains(f.url.pathExtension.lowercased()),
                      let cg = try? await AVAssetImageGenerator(asset: AVURLAsset(url: f.url)).image(at: CMTime(seconds: 1, preferredTimescale: 600)).image {
                out.append(Preview(name: f.name, date: nil, image: NSImage(cgImage: cg, size: .zero)))
            }
        }
        return out
    }
}

/// Lets AVFoundation decode a frame from a clip on the QNAP by reading only the byte ranges it asks for, over SSH.
final class RemoteVideo: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    let target: String, path: String, size: Int64, ext: String
    private let queue = DispatchQueue(label: "nasmover-remote-video")
    private static let chunk: Int64 = 4 << 20   // read at most 4 MB per request
    private var read: Int64 = 0                 // stop runaway reads
    private static let budget: Int64 = 48 << 20

    init(target: String, path: String, size: Int64, ext: String) {
        self.target = target; self.path = path; self.size = size; self.ext = ext
    }

    func frame() async -> NSImage? {
        let asset = AVURLAsset(url: URL(string: "nasmover-remote://clip." + ext)!)
        asset.resourceLoader.setDelegate(self, queue: queue)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 480, height: 480)
        let duration = (try? await asset.load(.duration))?.seconds ?? 2
        let at = CMTime(seconds: min(2, max(0, duration / 3)), preferredTimescale: 600)
        guard let cg = try? await gen.image(at: at).image else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    func resourceLoader(_ loader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource req: AVAssetResourceLoadingRequest) -> Bool {
        if let info = req.contentInformationRequest {
            info.contentType = (ext == "mov" ? UTType.quickTimeMovie : UTType.mpeg4Movie).identifier
            info.contentLength = size
            info.isByteRangeAccessSupported = true
        }
        guard let dr = req.dataRequest else { req.finishLoading(); return true }
        let offset = dr.requestedOffset
        let want = dr.requestsAllDataToEndOfResource ? size - offset : Int64(dr.requestedLength)
        let length = min(want, Self.chunk, size - offset)
        guard length > 0, read < Self.budget else {
            req.finishLoading(with: SSHError(message: "preview read limit"))
            return true
        }
        read += length
        // dd reads whole 64 KB blocks; trim to the exact range afterwards.
        let bs: Int64 = 65536
        let first = offset / bs, last = (offset + length - 1) / bs
        let cmd = "dd if=\(shq(path)) bs=\(bs) skip=\(first) count=\(last - first + 1) 2>/dev/null"
        Task {
            guard let r = try? await SSH.run(target, cmd), r.code == 0 else {
                req.finishLoading(with: SSHError(message: "couldn't read the clip"))
                return
            }
            let start = Int(offset - first * bs)
            let end = min(r.out.count, start + Int(length))
            guard start < end else { req.finishLoading(with: SSHError(message: "short read")); return }
            dr.respond(with: r.out.subdata(in: start..<end))
            req.finishLoading()
        }
        return true
    }
}
