/// How a picture is cut into horizontal strips, each encoded on its own
/// (Apple Screen Sharing sends a display as four). Strip heights are
/// multiples of 16 pixels, the last one takes the rest.
public enum TileLayout {
    public static func strips(pixelHeight: Int, count: Int) -> [(y: Int, height: Int)] {
        let count = max(1, min(count, 8, pixelHeight / 16))
        guard count > 1 else { return [(0, pixelHeight)] }
        let height = (pixelHeight / count) / 16 * 16
        return (0..<count).map { index in
            let y = index * height
            return (y, index == count - 1 ? pixelHeight - y : height)
        }
    }
}
