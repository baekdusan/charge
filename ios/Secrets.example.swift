import Foundation

// 이 파일을 Secrets.swift 로 복사한 뒤 자신의 Gist raw URL 로 바꾸세요.
// URL 형식: https://gist.githubusercontent.com/<username>/<gist_id>/raw/charge.json
enum Secrets {
    static let gistRawURL = URL(string: "https://gist.githubusercontent.com/USERNAME/GIST_ID/raw/charge.json")!
}
