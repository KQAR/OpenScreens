import Foundation

/// A version as releases are numbered: `1.2`, `1.2.0`, `1.10.3`.
///
/// Compared a number at a time, so that 1.10 comes after 1.9, and with
/// missing numbers counted as zero, so that 1.2 and 1.2.0 are the same
/// release.
public struct AppVersion: Hashable, Sendable, CustomStringConvertible {
    public let components: [Int]

    /// - Returns: `nil` for anything that is not numbers with dots between.
    public init?(_ string: String) {
        let parts = string.trimmingCharacters(in: .whitespaces).split(separator: ".", omittingEmptySubsequences: false)
        var components: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy(\.isASCII), part.allSatisfy(\.isNumber),
                  let number = Int(part) else { return nil }
            components.append(number)
        }
        guard !components.isEmpty else { return nil }
        self.components = components
    }

    /// The version of the app that is running.
    public static var current: AppVersion? {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String).flatMap(AppVersion.init)
    }

    public var description: String {
        components.map(String.init).joined(separator: ".")
    }

    /// The numbers without the zeros at the end that change nothing.
    private var significant: ArraySlice<Int> {
        var end = components.count
        while end > 1, components[end - 1] == 0 {
            end -= 1
        }
        return components[..<end]
    }

    public static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        lhs.significant == rhs.significant
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(Array(significant))
    }
}

extension AppVersion: Comparable {
    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        for index in 0..<max(lhs.components.count, rhs.components.count) {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }
}
