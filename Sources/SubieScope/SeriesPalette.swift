/// Categorical series colors in a fixed order, with separate steps for light and
/// dark appearance (validated reference palette from the dataviz guidelines).
enum SeriesPalette {
    static let light = [0x2a78d6, 0xeb6834, 0x1baf7a, 0xeda100, 0xe87ba4, 0x008300, 0x4a3aa7, 0xe34948]
    static let dark = [0x3987e5, 0xd95926, 0x199e70, 0xc98500, 0xd55181, 0x008300, 0x9085e9, 0xe66767]
    static let count = light.count
}
