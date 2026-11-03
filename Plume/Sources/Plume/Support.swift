import Foundation

/// Le lien « Soutenir Plume ».
///
/// Plume est libre et sous licence MIT : elle ne se vend pas. Si elle sert
/// vraiment, ce lien permet de laisser un pourboire — rien n'est verrouillé,
/// rien ne change dans l'app.
///
/// Pour changer la destination : une seule ligne à modifier ici (et la même
/// adresse dans `site/index.html` et le README).
enum Support {
    static let url = "https://buymeacoffee.com/ppocass"

    static var isConfigured: Bool { !url.isEmpty }
}
