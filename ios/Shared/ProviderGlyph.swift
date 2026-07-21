import SwiftUI

/// 프로바이더 식별용 단색 마크 (24×24 좌표계 SVG 패스를 그대로 그린다).
///
/// 상표 관련: 이 마크들은 각 사의 상표이며, 데이터의 출처 서비스를 지칭하기 위한
/// 지명적 사용(nominative use)으로 **앱 내부 UI에서만** 사용한다.
/// 앱 아이콘·스토어 스크린샷·마케팅 자산에는 사용하지 않는다.
struct ProviderGlyph: View {
    let providerId: String
    var name: String = ""

    var body: some View {
        if let path = ProviderMarks.mark(for: providerId) {
            MarkShape(source: path)
                .aspectRatio(1, contentMode: .fit)
        } else {
            monogram
        }
    }

    /// 마크가 없는 프로바이더는 첫 글자 모노그램으로
    private var monogram: some View {
        GeometryReader { geo in
            ZStack {
                Circle().stroke(lineWidth: max(1, geo.size.width * 0.08))
                Text(String((name.isEmpty ? providerId : name).prefix(1)).uppercased())
                    .font(.system(size: geo.size.width * 0.55, weight: .bold, design: .rounded))
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

/// 24×24 기준 패스를 대상 rect에 맞춰 스케일하는 Shape
struct MarkShape: Shape {
    let source: Path

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 24
        let dx = rect.midX - 12 * scale
        let dy = rect.midY - 12 * scale
        return source.applying(
            CGAffineTransform(scaleX: scale, y: scale)
                .concatenating(CGAffineTransform(translationX: dx, y: dy))
        )
    }
}

enum ProviderMarks {
    /// simple-icons 패스 데이터 (24×24, CC0 배포 — 상표권은 각 사에 귀속)
    private static let claudeD = "m4.7144 15.9555 4.7174-2.6471.079-.2307-.079-.1275h-.2307l-.7893-.0486-2.6956-.0729-2.3375-.0971-2.2646-.1214-.5707-.1215-.5343-.7042.0546-.3522.4797-.3218.686.0608 1.5179.1032 2.2767.1578 1.6514.0972 2.4468.255h.3886l.0546-.1579-.1336-.0971-.1032-.0972L6.973 9.8356l-2.55-1.6879-1.3356-.9714-.7225-.4918-.3643-.4614-.1578-1.0078.6557-.7225.8803.0607.2246.0607.8925.686 1.9064 1.4754 2.4893 1.8336.3643.3035.1457-.1032.0182-.0728-.164-.2733-1.3539-2.4467-1.445-2.4893-.6435-1.032-.17-.6194c-.0607-.255-.1032-.4674-.1032-.7285L6.287.1335 6.6997 0l.9957.1336.419.3642.6192 1.4147 1.0018 2.2282 1.5543 3.0296.4553.8985.2429.8318.091.255h.1579v-.1457l.1275-1.706.2368-2.0947.2307-2.6957.0789-.7589.3764-.9107.7468-.4918.5828.2793.4797.686-.0668.4433-.2853 1.8517-.5586 2.9021-.3643 1.9429h.2125l.2429-.2429.9835-1.3053 1.6514-2.0643.7286-.8196.85-.9046.5464-.4311h1.0321l.759 1.1293-.34 1.1657-1.0625 1.3478-.8804 1.1414-1.2628 1.7-.7893 1.36.0729.1093.1882-.0183 2.8535-.607 1.5421-.2794 1.8396-.3157.8318.3886.091.3946-.3278.8075-1.967.4857-2.3072.4614-3.4364.8136-.0425.0304.0486.0607 1.5482.1457.6618.0364h1.621l3.0175.2247.7892.522.4736.6376-.079.4857-1.2142.6193-1.6393-.3886-3.825-.9107-1.3113-.3279h-.1822v.1093l1.0929 1.0686 2.0035 1.8092 2.5075 2.3314.1275.5768-.3218.4554-.34-.0486-2.2039-1.6575-.85-.7468-1.9246-1.621h-.1275v.17l.4432.6496 2.3436 3.5214.1214 1.0807-.17.3521-.6071.2125-.6679-.1214-1.3721-1.9246L14.38 17.959l-1.1414-1.9428-.1397.079-.674 7.2552-.3156.3703-.7286.2793-.6071-.4614-.3218-.7468.3218-1.4753.3886-1.9246.3157-1.53.2853-1.9004.17-.6314-.0121-.0425-.1397.0182-1.4328 1.9672-2.1796 2.9446-1.7243 1.8456-.4128.164-.7164-.3704.0667-.6618.4008-.5889 2.386-3.0357 1.4389-1.882.929-1.0868-.0062-.1579h-.0546l-6.3385 4.1164-1.1293.1457-.4857-.4554.0608-.7467.2307-.2429 1.9064-1.3114Z"
    private static let openaiD = "M22.2819 9.8211a5.9847 5.9847 0 0 0-.5157-4.9108 6.0462 6.0462 0 0 0-6.5098-2.9A6.0651 6.0651 0 0 0 4.9807 4.1818a5.9847 5.9847 0 0 0-3.9977 2.9 6.0462 6.0462 0 0 0 .7427 7.0966 5.98 5.98 0 0 0 .511 4.9107 6.051 6.051 0 0 0 6.5146 2.9001A5.9847 5.9847 0 0 0 13.2599 24a6.0557 6.0557 0 0 0 5.7718-4.2058 5.9894 5.9894 0 0 0 3.9977-2.9001 6.0557 6.0557 0 0 0-.7475-7.0729zm-9.022 12.6081a4.4755 4.4755 0 0 1-2.8764-1.0408l.1419-.0804 4.7783-2.7582a.7948.7948 0 0 0 .3927-.6813v-6.7369l2.02 1.1686a.071.071 0 0 1 .038.052v5.5826a4.504 4.504 0 0 1-4.4945 4.4944zm-9.6607-4.1254a4.4708 4.4708 0 0 1-.5346-3.0137l.142.0852 4.783 2.7582a.7712.7712 0 0 0 .7806 0l5.8428-3.3685v2.3324a.0804.0804 0 0 1-.0332.0615L9.74 19.9502a4.4992 4.4992 0 0 1-6.1408-1.6464zM2.3408 7.8956a4.485 4.485 0 0 1 2.3655-1.9728V11.6a.7664.7664 0 0 0 .3879.6765l5.8144 3.3543-2.0201 1.1685a.0757.0757 0 0 1-.071 0l-4.8303-2.7865A4.504 4.504 0 0 1 2.3408 7.872zm16.5963 3.8558L13.1038 8.364 15.1192 7.2a.0757.0757 0 0 1 .071 0l4.8303 2.7913a4.4944 4.4944 0 0 1-.6765 8.1042v-5.6772a.79.79 0 0 0-.407-.667zm2.0107-3.0231l-.142-.0852-4.7735-2.7818a.7759.7759 0 0 0-.7854 0L9.409 9.2297V6.8974a.0662.0662 0 0 1 .0284-.0615l4.8303-2.7866a4.4992 4.4992 0 0 1 6.6802 4.66zM8.3065 12.863l-2.02-1.1638a.0804.0804 0 0 1-.038-.0567V6.0742a4.4992 4.4992 0 0 1 7.3757-3.4537l-.142.0805L8.704 5.459a.7948.7948 0 0 0-.3927.6813zm1.0976-2.3654l2.602-1.4998 2.6069 1.4998v2.9994l-2.5974 1.4997-2.6067-1.4997Z"

    private static let cache: [String: Path] = [
        "claude": SVGPathParser.parse(claudeD),
        "openai": SVGPathParser.parse(openaiD),
    ]

    static func mark(for providerId: String) -> Path? {
        switch providerId.lowercased() {
        case "claude": return cache["claude"]
        case "codex", "openai", "azure-openai": return cache["openai"]
        default: return nil
        }
    }
}

/// 필요한 명령(M L H V C A Z + 소문자)만 지원하는 최소 SVG 패스 파서
enum SVGPathParser {
    static func parse(_ d: String) -> Path {
        var path = Path()
        var numbers: [Double] = []
        var current = CGPoint.zero
        var subpathStart = CGPoint.zero
        var index = d.startIndex

        func scanNumbers() -> [Double] {
            var result: [Double] = []
            var token = ""
            func flush() {
                if let v = Double(token) { result.append(v) }
                token = ""
            }
            while index < d.endIndex {
                let ch = d[index]
                if ch.isLetter { break }
                if ch == "," || ch == " " || ch == "\n" {
                    flush()
                } else if ch == "-", !token.isEmpty, token.last != "e", token.last != "E" {
                    flush(); token = "-"
                } else if ch == ".", token.contains(".") {
                    // "1.5.5" 같은 축약 표기: 새 숫자 시작
                    flush(); token = "."
                } else {
                    token.append(ch)
                }
                index = d.index(after: index)
            }
            flush()
            return result
        }

        while index < d.endIndex {
            let cmd = d[index]
            index = d.index(after: index)
            guard cmd.isLetter else { continue }
            numbers = scanNumbers()
            let rel = cmd.isLowercase
            var i = 0
            func take(_ n: Int) -> [Double]? {
                guard i + n <= numbers.count else { return nil }
                defer { i += n }
                return Array(numbers[i..<i+n])
            }
            switch Character(cmd.uppercased()) {
            case "M":
                var first = true
                while let v = take(2) {
                    let p = rel ? CGPoint(x: current.x + v[0], y: current.y + v[1]) : CGPoint(x: v[0], y: v[1])
                    if first { path.move(to: p); subpathStart = p; first = false } else { path.addLine(to: p) }
                    current = p
                }
            case "L":
                while let v = take(2) {
                    let p = rel ? CGPoint(x: current.x + v[0], y: current.y + v[1]) : CGPoint(x: v[0], y: v[1])
                    path.addLine(to: p); current = p
                }
            case "H":
                while let v = take(1) {
                    let p = CGPoint(x: rel ? current.x + v[0] : v[0], y: current.y)
                    path.addLine(to: p); current = p
                }
            case "V":
                while let v = take(1) {
                    let p = CGPoint(x: current.x, y: rel ? current.y + v[0] : v[0])
                    path.addLine(to: p); current = p
                }
            case "C":
                while let v = take(6) {
                    let o = rel ? current : .zero
                    let c1 = CGPoint(x: o.x + v[0], y: o.y + v[1])
                    let c2 = CGPoint(x: o.x + v[2], y: o.y + v[3])
                    let p = CGPoint(x: o.x + v[4], y: o.y + v[5])
                    path.addCurve(to: p, control1: c1, control2: c2); current = p
                }
            case "A":
                while let v = take(7) {
                    let end = rel
                        ? CGPoint(x: current.x + v[5], y: current.y + v[6])
                        : CGPoint(x: v[5], y: v[6])
                    addArc(&path, from: current, rx: v[0], ry: v[1],
                           rotationDeg: v[2], largeArc: v[3] != 0, sweep: v[4] != 0, to: end)
                    current = end
                }
            case "Z":
                path.closeSubpath(); current = subpathStart
            default:
                break
            }
        }
        return path
    }

    /// SVG 원호를 베지어 곡선들로 변환 (W3C 끝점→중심 파라미터화)
    private static func addArc(_ path: inout Path, from p0: CGPoint,
                               rx rxIn: Double, ry ryIn: Double,
                               rotationDeg: Double, largeArc: Bool, sweep: Bool, to p1: CGPoint) {
        var rx = abs(rxIn), ry = abs(ryIn)
        if rx == 0 || ry == 0 || p0 == p1 {
            path.addLine(to: p1); return
        }
        let phi = rotationDeg * .pi / 180
        let cosPhi = cos(phi), sinPhi = sin(phi)
        let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
        let x1p = cosPhi * dx + sinPhi * dy
        let y1p = -sinPhi * dx + cosPhi * dy
        let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
        if lambda > 1 { let s = sqrt(lambda); rx *= s; ry *= s }
        let num = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p
        let den = rx * rx * y1p * y1p + ry * ry * x1p * x1p
        var coef = sqrt(max(0, num / den))
        if largeArc == sweep { coef = -coef }
        let cxp = coef * rx * y1p / ry
        let cyp = -coef * ry * x1p / rx
        let cx = cosPhi * cxp - sinPhi * cyp + (p0.x + p1.x) / 2
        let cy = sinPhi * cxp + cosPhi * cyp + (p0.y + p1.y) / 2

        func angle(_ ux: Double, _ uy: Double, _ vx: Double, _ vy: Double) -> Double {
            let dot = ux * vx + uy * vy
            let len = sqrt((ux * ux + uy * uy) * (vx * vx + vy * vy))
            var a = acos(min(1, max(-1, dot / len)))
            if ux * vy - uy * vx < 0 { a = -a }
            return a
        }
        let theta1 = angle(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
        var delta = angle((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry)
        if !sweep && delta > 0 { delta -= 2 * .pi }
        if sweep && delta < 0 { delta += 2 * .pi }

        let segments = max(1, Int(ceil(abs(delta) / (.pi / 2))))
        let segDelta = delta / Double(segments)
        let t = 4.0 / 3.0 * tan(segDelta / 4)
        var start = theta1
        for _ in 0..<segments {
            let end = start + segDelta
            let cosS = cos(start), sinS = sin(start)
            let cosE = cos(end), sinE = sin(end)
            func point(_ c: Double, _ s: Double) -> CGPoint {
                CGPoint(x: cx + rx * cosPhi * c - ry * sinPhi * s,
                        y: cy + rx * sinPhi * c + ry * cosPhi * s)
            }
            func derivative(_ c: Double, _ s: Double) -> CGPoint {
                CGPoint(x: -rx * cosPhi * s - ry * sinPhi * c,
                        y: -rx * sinPhi * s + ry * cosPhi * c)
            }
            let pStart = point(cosS, sinS)
            let pEnd = point(cosE, sinE)
            let dStart = derivative(cosS, sinS)
            let dEnd = derivative(cosE, sinE)
            let c1 = CGPoint(x: pStart.x + t * dStart.x, y: pStart.y + t * dStart.y)
            let c2 = CGPoint(x: pEnd.x - t * dEnd.x, y: pEnd.y - t * dEnd.y)
            path.addCurve(to: pEnd, control1: c1, control2: c2)
            start = end
        }
    }
}
