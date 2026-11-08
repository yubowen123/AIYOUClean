import Foundation
import CleanRoomCore
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let roots = (0..<10).map { root.appendingPathComponent(String(format:"%03d",$0)) }
for round in 1...5 {
    let r = Scanner().scan(.duplicates, options: ScanOptions(roots: roots))
    print("round=\(round) visited=\(r.visitedFiles) truncated=\(r.truncated) rssBytes=\(ProcessResources.residentBytes() ?? 0)")
    fflush(stdout)
}
