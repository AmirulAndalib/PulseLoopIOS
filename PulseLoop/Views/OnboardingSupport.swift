import Foundation

enum OnboardingStep: String, CaseIterable, Codable, Identifiable {
    case welcome
    case ring
    case profile
    case goals
    case baseline

    var id: String { rawValue }
    var index: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}

struct OnboardingProgressStore {
    static let storageKey = "onboarding.route.v2"

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadPath() -> [OnboardingStep] {
        guard let values = defaults.stringArray(forKey: Self.storageKey) else { return [.welcome] }
        let path = values.compactMap(OnboardingStep.init(rawValue:))
        guard path.first == .welcome, !path.isEmpty else { return [.welcome] }
        return path
    }

    func savePath(_ path: [OnboardingStep]) {
        let safePath = path.first == .welcome && !path.isEmpty ? path : [.welcome]
        defaults.set(safePath.map(\.rawValue), forKey: Self.storageKey)
    }

    func clear() {
        defaults.removeObject(forKey: Self.storageKey)
    }
}

struct ProfileDraft: Equatable {
    var name = ""
    var age: Int?
    var sex: String?
    var heightCm: Double?
    var weightKg: Double?
    var units: UnitsPreference

    init(profile: UserProfile? = nil, locale: Locale = .current) {
        name = profile?.name ?? ""
        age = profile?.age
        sex = profile?.sex
        heightCm = profile?.heightCm
        weightKg = profile?.weightKg
        units = profile?.units ?? Self.preferredUnits(for: locale)
    }

    static func preferredUnits(for locale: Locale) -> UnitsPreference {
        locale.measurementSystem == .us ? .imperial : .metric
    }

    var heightDisplayValue: Int? {
        guard let heightCm else { return nil }
        return units == .metric ? Int(heightCm.rounded()) : Int((heightCm / 2.54).rounded())
    }

    var weightDisplayValue: Int? {
        guard let weightKg else { return nil }
        return units == .metric ? Int(weightKg.rounded()) : Int((weightKg * 2.2046226).rounded())
    }

    mutating func setHeight(displayValue: Int?) {
        guard let displayValue else { heightCm = nil; return }
        heightCm = units == .metric ? Double(displayValue) : Double(displayValue) * 2.54
    }

    mutating func setWeight(displayValue: Int?) {
        guard let displayValue else { weightKg = nil; return }
        weightKg = units == .metric ? Double(displayValue) : Double(displayValue) / 2.2046226
    }

    func apply(to profile: UserProfile) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.name = trimmed.isEmpty ? nil : trimmed
        profile.age = age
        profile.sex = sex
        profile.heightCm = heightCm
        profile.weightKg = weightKg
        profile.units = units
        profile.updatedAt = Date()
    }
}

struct GoalDraft: Equatable {
    static let recommendedDistanceMeters = 8_000.0

    var steps: Double = 10_000
    var distance: Double
    var calories: Double = 500
    var activeMinutes: Double = 45
    var sleepHours: Double = 8
    var workouts: Double = 4

    init(goal: UserGoal? = nil, units: UnitsPreference) {
        let metersPerUnit = Self.metersPerUnit(for: units)
        if let goal {
            steps = Double(goal.steps)
            distance = (goal.distanceMeters / metersPerUnit * 10).rounded() / 10
            calories = Double(goal.calories)
            activeMinutes = Double(goal.activeMinutes)
            sleepHours = Double(goal.sleepMinutes) / 60
            workouts = Double(goal.workoutsPerWeek)
        } else {
            distance = (Self.recommendedDistanceMeters / metersPerUnit * 10).rounded() / 10
        }
    }

    static func metersPerUnit(for units: UnitsPreference) -> Double {
        units == .metric ? 1_000 : 1_609.344
    }

    func apply(to goal: UserGoal, units: UnitsPreference, includeWeeklyWorkouts: Bool) {
        goal.steps = Int(steps)
        goal.distanceMeters = distance * Self.metersPerUnit(for: units)
        goal.calories = Int(calories)
        goal.activeMinutes = Int(activeMinutes)
        goal.sleepMinutes = Int(sleepHours * 60)
        if includeWeeklyWorkouts {
            goal.workoutsPerWeek = Int(workouts)
        }
        goal.updatedAt = Date()
    }
}
