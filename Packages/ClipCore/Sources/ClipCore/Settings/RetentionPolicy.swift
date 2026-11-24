import Foundation

/// How long unpinned history is kept. Pinned items and pinboard items are never removed.
public enum RetentionPolicy: String, Codable, CaseIterable, Sendable, Identifiable {
    case day
    case week
    case month
    case year
    case forever

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .day: return "1 Day"
        case .week: return "1 Week"
        case .month: return "1 Month"
        case .year: return "1 Year"
        case .forever: return "Forever"
        }
    }

    /// Items last used before this date are eligible for deletion; nil = keep forever.
    public func cutoffDate(from now: Date = Date(), calendar: Calendar = Calendar.current) -> Date? {
        switch self {
        case .day: return calendar.date(byAdding: .day, value: -1, to: now)
        case .week: return calendar.date(byAdding: .day, value: -7, to: now)
        case .month: return calendar.date(byAdding: .month, value: -1, to: now)
        case .year: return calendar.date(byAdding: .year, value: -1, to: now)
        case .forever: return nil
        }
    }
}
