import Foundation

// Translations live in Resources/Localization/<lang>.lproj/Localizable.strings
// and are copied into the app bundle by scripts/build.sh. English is the key.
//
// String(localized:) builds the key from interpolations by type:
// Int → %lld, String → %@. Numbers that read differently per language
// (percent, durations) are formatted first and passed in as %@.

/// The language the app is actually showing (en / tr / es), with the user's
/// region, so numbers read the same way as the words around them.
let appLocale: Locale = {
    let lang = Bundle.main.preferredLocalizations.first ?? "en"
    let region = Locale.current.region?.identifier
    return Locale(identifier: region.map { "\(lang)_\($0)" } ?? lang)
}()

/// Numbers follow the language only ("80%" next to English words even in a
/// Turkish region), so a sentence never mixes conventions.
let numberLocale = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")

/// Looks up a user-facing string in the app's Localizable.strings.
func L(_ value: String.LocalizationValue) -> String {
    String(localized: value)
}

/// "80%" in English, "%80" in Turkish, "80 %" in Spanish.
func pct(_ value: Int) -> String {
    let f = NumberFormatter()
    f.locale = numberLocale
    f.numberStyle = .percent
    f.maximumFractionDigits = 0
    return f.string(from: NSNumber(value: Double(value) / 100)) ?? "\(value)%"
}

/// Percent with one decimal: "94.7%", "%94,7", "94,7 %".
func pct1(_ value: Double) -> String {
    let f = NumberFormatter()
    f.locale = numberLocale
    f.numberStyle = .percent
    f.minimumFractionDigits = 1
    f.maximumFractionDigits = 1
    return f.string(from: NSNumber(value: value / 100)) ?? String(format: "%.1f%%", value)
}

/// "1hr 12min", "1 sa. 12 dk.", "1 h 12 min" – the two largest units.
func shortDuration(minutes: Int) -> String {
    let f = DateComponentsFormatter()
    var calendar = Calendar.current
    calendar.locale = appLocale
    f.calendar = calendar
    f.unitsStyle = .brief
    f.allowedUnits = minutes >= 72 * 60 ? [.day, .hour] : [.hour, .minute]
    f.maximumUnitCount = 2
    f.zeroFormattingBehavior = .dropAll
    return f.string(from: TimeInterval(max(0, minutes) * 60)) ?? "\(minutes)m"
}
