import Foundation

/// Modern single-source watch icons use a bitmap (part 220, dimension2=1)
/// plus a multisize lookup (part 218, dimension2=0). Observed in the same-source
/// Xcode 26.6 watchOS 10 deployment catalog; corroborated by CoreUI's
/// CSIGenerator.initWithMultisizeImageSetNamed:sizesByIndex: (layout 1010)
/// and _CUIThemeMultisizeImageSetRendition (SISM, version 1, uint32 entries).
/// The master is watch idiom 5 at scale 1, NOT marketing idiom 6.
enum WatchIconIndex {
    private struct UnsupportedIcon: Error, CustomStringConvertible {
        var description: String
    }

    static func entries(for renditions: [Rendition]) throws -> [BOMTree.Entry] {
        var entries: [BOMTree.Entry] = []
        var names = Set<String>()
        for rendition in renditions where rendition.idiom == .watch {
            guard case .bitmap(let body) = rendition.body, body.kind == .appIcon else { continue }
            guard names.insert(rendition.name).inserted,
                  rendition.scale == .x1, body.width == 1024, body.height == 1024 else {
                throw UnsupportedIcon(description: "Watch app icons require one 1024x1024 scale-1 master per name")
            }
            var key = RenditionKey(rendition: rendition)
            key.dimension2 = 0
            key.part = 218
            var payload = ByteWriter()
            payload.writeLE(UInt32(0x4D534953)) // On-disk SISM.
            payload.writeLE(UInt32(1))
            payload.writeLE(UInt32(1)) // One indexed size.
            payload.writeLE(body.width)
            payload.writeLE(body.height)
            payload.writeLE(UInt32(1)) // Matches bitmap dimension2.
            let tvl = CSITVL.encode([.colorScale, .bitmapFlag])
            let header = CSIHeader.encode(
                renditionFlags: 0, width: 0, height: 0, scaleFactor: 0,
                pixelFormat: 0, colorSpace: 0, layout: .multisizeImageSet,
                name: rendition.name, tvlLength: UInt32(tvl.count),
                bitmapCount: 1, renditionLength: UInt32(payload.data.count)
            )
            entries.append(BOMTree.Entry(key: key.encode(), value: header + tvl + payload.data))
        }
        return entries
    }
}
