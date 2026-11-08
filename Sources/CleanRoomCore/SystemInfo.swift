import Foundation

public struct CommandResult: Sendable {
    public let code: Int32
    public let output: String
}
public enum CommandRunner {
    /// Direct argv execution, bounded runtime and file-backed output to avoid a full-pipe deadlock.
    public static func run(_ path: String, _ arguments: [String], timeout: TimeInterval = 10) -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath:path); process.arguments = arguments
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("cleanroom-command-" + UUID().uuidString)
        guard FileManager.default.createFile(atPath:temp.path,contents:nil,attributes:[.posixPermissions:0o600]), let handle = try? FileHandle(forWritingTo:temp) else { return CommandResult(code:-1,output:"无法创建命令输出文件") }
        defer { try? handle.close(); try? FileManager.default.removeItem(at:temp) }
        process.standardOutput = handle; process.standardError = handle
        do { try process.run() } catch { return CommandResult(code:-1,output:error.localizedDescription) }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval:0.03) }
        var timedOut = false
        if process.isRunning {
            timedOut = true; process.terminate()
            let grace = Date().addingTimeInterval(1)
            while process.isRunning && Date() < grace { Thread.sleep(forTimeInterval:0.02) }
            if process.isRunning { kill(process.processIdentifier,SIGKILL) }
        }
        process.waitUntilExit()
        let output: String
        if let reader = try? FileHandle(forReadingFrom:temp) {
            output = String(data:(try? reader.read(upToCount:1_048_576)) ?? Data(),encoding:.utf8) ?? "无法解码命令输出"
            try? reader.close()
        } else { output = "无法读取命令输出" }
        return CommandResult(code:timedOut ? -2 : process.terminationStatus,output:output + (timedOut ? "\n命令超时" : ""))
    }
}

public enum SystemInfo {
    public static func snapshot() -> SystemSnapshot {
        let p = ProcessInfo.processInfo
        let values = try? URL(fileURLWithPath:NSHomeDirectory()).resourceValues(forKeys:[.volumeTotalCapacityKey,.volumeAvailableCapacityKey])
        var loads = [Double](repeating:0,count:3)
        getloadavg(&loads,3)
        let battery = CommandRunner.run("/usr/bin/pmset",["-g","batt"],timeout:3).output.trimmingCharacters(in:.whitespacesAndNewlines)
        return SystemSnapshot(host:p.hostName,os:p.operatingSystemVersionString,totalDisk:Int64(values?.volumeTotalCapacity ?? 0),availableDisk:Int64(values?.volumeAvailableCapacity ?? 0),totalMemory:p.physicalMemory,processors:p.processorCount,uptime:p.systemUptime,loadAverage:loads.map { String(format:"%.2f",$0) }.joined(separator:" / "),battery:battery)
    }
}
