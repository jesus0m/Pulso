import XCTest
@testable import Pulso

final class LocalizationTests: XCTestCase {
    func testSpanishAndEnglishResourcesAreEmbeddedInEveryShippedBundle() throws {
        let app = Bundle.main
        let widget = try bundle("PlugIns/PulsoWidgets.appex", in: app)
        let watch = try bundle("Watch/PulsoWatch.app", in: app)
        let complication = try bundle("PlugIns/PulsoWatchWidgets.appex", in: watch)
        let samples = [
            ("Conexiones", "Connections"),
            ("Web del desarrollador", "Developer website"),
            ("En curso", "Running"),
            ("Renovación pendiente", "Reset pending"),
            ("La sesión ha caducado o el token no es válido.", "The session has expired or the token is invalid."),
            ("Semana · Opus", "Week · Opus"),
            ("Créditos usados · cuenta", "Credits used · account"),
            ("Actualizar cuotas", "Refresh quotas")
        ]
        for target in [app, widget, watch, complication] {
            for language in ["es", "en"] {
                let localized = try languageBundle(language, in: target)
                for (spanish, english) in samples {
                    XCTAssertEqual(
                        localized.localizedString(forKey: spanish, value: nil, table: "Localizable"),
                        language == "es" ? spanish : english,
                        "\(target.bundleURL.lastPathComponent), \(language), \(spanish)"
                    )
                }
            }
        }
    }

    func testInterpolatedErrorsAndQuotaTitlesResolveFromTheSelectedLanguageBundle() throws {
        for (language, error, window) in [
            ("es", "El proveedor no pudo completar la consulta (HTTP 429).", "Semana · 7 d"),
            ("en", "The provider could not complete the request (HTTP 429).", "Week · 7 d")
        ] {
            let localized = try languageBundle(language, in: .main)
            let locale = Locale(identifier: language)
            let code = 429
            let duration = "7 d"
            XCTAssertEqual(
                String(localized: "El proveedor no pudo completar la consulta (HTTP \(code)).",
                       bundle: localized, locale: locale),
                error
            )
            XCTAssertEqual(
                String(localized: "Semana · \(duration)", bundle: localized, locale: locale),
                window
            )
        }
    }

    func testLiveActivityQuotaCountsUseSingularAndPluralForms() throws {
        for (language, singular, plural) in [
            ("es", "+1 cuota", "+2 cuotas"),
            ("en", "+1 quota", "+2 quotas")
        ] {
            let localized = try languageBundle(language, in: .main)
            let locale = Locale(identifier: language)
            let one = 1
            let two = 2
            XCTAssertEqual(String(localized: "+\(one) cuotas", bundle: localized, locale: locale), singular)
            XCTAssertEqual(String(localized: "+\(two) cuotas", bundle: localized, locale: locale), plural)
        }
    }

    private func bundle(_ path: String, in parent: Bundle) throws -> Bundle {
        try XCTUnwrap(Bundle(url: parent.bundleURL.appendingPathComponent(path)), path)
    }

    private func languageBundle(_ language: String, in parent: Bundle) throws -> Bundle {
        let url = try XCTUnwrap(parent.url(forResource: language, withExtension: "lproj"), language)
        return try XCTUnwrap(Bundle(url: url), url.path)
    }
}
