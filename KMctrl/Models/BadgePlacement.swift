import Foundation

/// Where the "Controlled by …" badge sits: bottom-right of the visible screen area by
/// default (clear of title bars and the Dock), or wherever the user last dragged it, pulled
/// back on-screen if that spot no longer fits.
enum BadgePlacement {
    static let margin: CGFloat = 16

    static func origin(size: CGSize, visibleFrame v: CGRect, saved: CGPoint?) -> CGPoint {
        let fallback = CGPoint(x: v.maxX - size.width - margin, y: v.minY + margin)
        guard let s = saved else { return fallback }
        let fits = s.x >= v.minX && s.y >= v.minY && s.x + size.width <= v.maxX && s.y + size.height <= v.maxY
        return fits ? s : fallback
    }
}
