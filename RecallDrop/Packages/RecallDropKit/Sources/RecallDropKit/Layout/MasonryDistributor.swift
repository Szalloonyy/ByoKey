//
//  MasonryDistributor.swift
//  RecallDropKit
//
//  Column assignment for the masonry grid. Each card goes to the currently
//  shortest column, which keeps columns balanced while preserving the
//  newest-first order row by row. The views then render one lazy stack per
//  column, so only visible cards are built.
//

import Foundation

public enum MasonryDistributor {
    /// Indices of `heights` grouped by column.
    public static func distribute(heights: [Double], columns: Int, spacing: Double = 0) -> [[Int]] {
        let columnCount = max(1, columns)
        var buckets = Array(repeating: [Int](), count: columnCount)
        var totals = Array(repeating: 0.0, count: columnCount)
        for (index, height) in heights.enumerated() {
            var target = 0
            for column in 1..<columnCount where totals[column] < totals[target] - 0.5 {
                target = column
            }
            buckets[target].append(index)
            totals[target] += max(height, 0) + spacing
        }
        return buckets
    }

    /// How many columns of at least `minimumColumnWidth` fit into `width`.
    public static func columnCount(forWidth width: Double, minimumColumnWidth: Double, spacing: Double,
                                   maximumColumns: Int = 8) -> Int {
        guard width > 0, minimumColumnWidth > 0 else { return 1 }
        let count = Int((width + spacing) / (minimumColumnWidth + spacing))
        return min(max(count, 1), max(maximumColumns, 1))
    }

    /// Height-to-width ratio used for a card's image, clamped so extreme
    /// panoramas or long scrolling screenshots don't dominate the grid.
    public static func clampedAspectRatio(width: Double, height: Double, minimum: Double = 0.45,
                                          maximum: Double = 1.9, fallback: Double = 1.2) -> Double {
        guard width > 0, height > 0 else { return fallback }
        return min(max(height / width, minimum), maximum)
    }
}

/// Pixel math for downscaling images before OCR, thumbnails and upload.
public enum ImageSizing {
    /// Size that fits within `maxDimension` on the long edge, preserving aspect ratio.
    public static func fitting(width: Int, height: Int, maxDimension: Int) -> (width: Int, height: Int) {
        guard width > 0, height > 0, maxDimension > 0 else { return (max(width, 0), max(height, 0)) }
        let longest = max(width, height)
        guard longest > maxDimension else { return (width, height) }
        let scale = Double(maxDimension) / Double(longest)
        return (max(1, Int((Double(width) * scale).rounded())), max(1, Int((Double(height) * scale).rounded())))
    }
}
