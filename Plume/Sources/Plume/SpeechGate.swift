import Foundation

/// Ce qu'on envoie (ou pas) à Whisper.
///
/// 1. **La barrière anti-hallucination** : un détecteur d'activité vocale
///    simple (niveau, bruit de fond, durée de parole). Un enregistrement sans
///    vraie parole n'est JAMAIS envoyé : sur du silence, Whisper invente des
///    phrases comme « Sous-titrage Société Radio-Canada ».
/// 2. **Le découpage** : Whisper tourne avec `-ac 768`, qui ne couvre
///    qu'environ 15 s d'audio par passe ET, mesuré sur un M1, répète la
///    dernière phrase (ou invente un « Ah ! ») dès qu'un morceau dépasse ~9 s.
///    Une longue dictée est donc coupée en morceaux de **8 s maximum**, dans
///    un creux de la voix, et chaque morceau est transcrit à son tour (30 s de
///    dictée → ~6 s de transcription, aucune répétition ; sans `-ac` ce serait
///    juste aussi mais chaque phrase coûterait 2,2 s au lieu de 1,1 s).
enum SpeechGate {
    // Seuils mesurés sur des micros de Mac (silence, pièce, clic, voix).
    static let frameSamples = 4096
    static let silenceRms: Float = 0.008
    static let startFloor: Float = 0.012
    static let continueFloor: Float = 0.007
    static let noiseMultiplier: Float = 3
    static let peakCap: Float = 0.4
    static let startFrames = 3
    static let minSpeechSeconds = 0.35
    static let minSpeechRatio = 0.15
    static let preRollSeconds = 0.35
    static let padSeconds = 0.25

    struct Verdict {
        let range: Range<Int>?
        let reason: String
        let speechSeconds: Double
    }

    static func analyse(_ samples: [Float], sampleRate: Double = AudioRecorder.sampleRate) -> Verdict {
        let total = samples.count
        let frameCount = total / frameSamples
        guard frameCount >= 1 else { return Verdict(range: nil, reason: "trop court", speechSeconds: 0) }

        var levels = [Float](repeating: 0, count: frameCount)
        samples.withUnsafeBufferPointer { p in
            for f in 0..<frameCount {
                var sum: Float = 0
                let base = f * frameSamples
                for i in 0..<frameSamples { let v = p[base + i]; sum += v * v }
                levels[f] = (sum / Float(frameSamples)).squareRoot()
            }
        }

        let sorted = levels.sorted()
        let peak = sorted.last!
        if peak < silenceRms { return Verdict(range: nil, reason: "silence", speechSeconds: 0) }

        let noise = percentile(sorted, 0.1)
        let ceiling = peak * peakCap
        let threshold = max(startFloor, min(noise * noiseMultiplier, ceiling))
        let continueThreshold = max(continueFloor, min(noise * noiseMultiplier * 0.6, ceiling))

        var first = -1
        var streak = 0
        for i in 0..<frameCount {
            if levels[i] > threshold {
                streak += 1
                if streak >= startFrames { first = i - streak + 1; break }
            } else {
                streak = 0
            }
        }
        guard first >= 0 else { return Verdict(range: nil, reason: "pas de parole", speechSeconds: 0) }

        var last = first
        for i in first..<frameCount where levels[i] > continueThreshold { last = i }

        var speechFrames = 0
        for i in first...last where levels[i] > threshold { speechFrames += 1 }
        let speechSeconds = Double(speechFrames * frameSamples) / sampleRate
        if speechSeconds < minSpeechSeconds {
            return Verdict(range: nil, reason: "trop peu de parole", speechSeconds: speechSeconds)
        }

        let start = max(0, first * frameSamples - Int((preRollSeconds * sampleRate).rounded()))
        let end = min(total, (last + 1) * frameSamples + Int((padSeconds * sampleRate).rounded()))
        guard end - start >= frameSamples else { return Verdict(range: nil, reason: "trop court", speechSeconds: speechSeconds) }

        let ratio = speechSeconds / (Double(end - start) / sampleRate)
        if ratio < minSpeechRatio {
            return Verdict(range: nil, reason: "surtout du silence", speechSeconds: speechSeconds)
        }
        return Verdict(range: start..<end, reason: "parole", speechSeconds: speechSeconds)
    }

    private static func percentile(_ sorted: [Float], _ p: Double) -> Float {
        guard !sorted.isEmpty else { return 0 }
        let index = min(sorted.count - 1, max(0, Int((Double(sorted.count - 1) * p).rounded())))
        return sorted[index]
    }

    // MARK: Découpage

    /// Coupe `range` en morceaux de `maxSeconds` au plus, chacun terminé dans
    /// le passage le plus calme (fenêtre de 0,1 s) entre `minSeconds` et
    /// `maxSeconds` — donc entre deux mots, pas au milieu d'un.
    static let maxChunkSeconds: Double = 8

    static func chunks(of samples: [Float], range: Range<Int>,
                       maxSeconds: Double = maxChunkSeconds, minSeconds: Double = 3,
                       sampleRate: Double = AudioRecorder.sampleRate) -> [Range<Int>] {
        let maxLen = Int(maxSeconds * sampleRate)
        let minLen = Int(minSeconds * sampleRate)
        var out: [Range<Int>] = []
        var start = range.lowerBound
        while range.upperBound - start > maxLen {
            let cut = quietestPoint(in: samples, from: start + minLen, to: start + maxLen)
            out.append(start..<cut)
            start = cut
        }
        out.append(start..<range.upperBound)
        return out
    }

    /// Le milieu de la fenêtre de 0,25 s la plus calme entre `from` et `to` :
    /// là où on peut couper sans couper un mot. (0,1 s le 14/10 au départ :
    /// en dictée réelle au micro, ça tombait parfois DANS un mot — « la
    /// première partie soit transcrite » → « la première question. Je m'écris ».
    /// Une vraie pause entre deux mots dure, elle, au moins un quart de seconde.)
    static func quietestPoint(in samples: [Float], from: Int, to: Int, sampleRate: Double = AudioRecorder.sampleRate) -> Int {
        let window = Int(0.25 * sampleRate)
        let hop = Int(0.02 * sampleRate)
        var best = to
        var bestEnergy = Float.greatestFiniteMagnitude
        var w = max(0, from)
        while w + window <= min(to, samples.count) {
            var sum: Float = 0
            for i in w..<(w + window) { sum += samples[i] * samples[i] }
            if sum < bestEnergy { bestEnergy = sum; best = w + window / 2 }
            w += hop
        }
        return best
    }

    // MARK: WAV

    /// WAV canonique 16 kHz mono PCM16 (en-tête de 44 octets).
    static func wav(_ samples: ArraySlice<Float>, sampleRate: Double = AudioRecorder.sampleRate) -> Data {
        var data = Data(capacity: 44 + samples.count * 2)
        func ascii(_ s: String) { data.append(s.data(using: .ascii)!) }
        func le32(_ v: UInt32) { var v = v.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        func le16(_ v: UInt16) { var v = v.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        let rate = UInt32(sampleRate)
        let size = UInt32(samples.count * 2)
        ascii("RIFF"); le32(36 + size); ascii("WAVE")
        ascii("fmt "); le32(16); le16(1); le16(1); le32(rate); le32(rate * 2); le16(2); le16(16)
        ascii("data"); le32(size)
        var pcm = [Int16](repeating: 0, count: samples.count)
        for (i, s) in samples.enumerated() { pcm[i] = Int16(max(-1, min(1, s)) * 32767) }
        pcm.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }

    static func readWav(_ data: Data) -> [Float]? {
        guard data.count > 44 else { return nil }
        return data.subdata(in: 44..<data.count).withUnsafeBytes { raw in
            raw.bindMemory(to: Int16.self).map { Float($0) / 32768 }
        }
    }
}

/// Dernier filet après Whisper : ses formules inventées sur du silence.
/// Prudent : en dictée on peut vouloir écrire une
/// adresse web ou « à la prochaine », donc on ne jette que les génériques de
/// sous-titrage et les morceaux manifestement trop longs pour leur durée.
enum TranscriptFilter {
    static let creditPatterns = [
        "sous-titrage société radio-canada", "sous-titrage st'501", "sous-titres réalisés par la communauté d'amara.org",
        "sous-titres réalisés par", "sous-titrage par", "merci d'avoir regardé cette vidéo",
        "thanks for watching", "subtitles by the amara.org community",
    ]

    static func clean(_ text: String, audioSeconds: Double) -> String {
        // Whisper rend un segment par ligne : on recolle en une phrase, et on
        // retire un segment répété à l'identique (le défaut de `-ac`).
        var segments: [String] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let seg = line.trimmingCharacters(in: .whitespaces)
            guard !seg.isEmpty else { continue }
            if let previous = segments.last, normalize(previous) == normalize(seg) { continue }
            segments.append(seg)
        }
        var t = segments.joined(separator: " ")
        let lower = t.lowercased()
        for pattern in creditPatterns where lower.contains(pattern) {
            if let r = t.range(of: pattern, options: [.caseInsensitive, .diacriticInsensitive]) {
                t.removeSubrange(r)
            }
        }
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.contains(where: { $0.isLetter || $0.isNumber }) else { return "" }
        // Un humain plafonne vers 5-6 mots/s : au-delà de 8, Whisper invente.
        let words = t.split(whereSeparator: { $0.isWhitespace }).count
        if audioSeconds > 0.5, Double(words) / audioSeconds > 8 { return "" }
        return t
    }

    static func normalize(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .filter { $0.isLetter || $0.isNumber }
    }
}
