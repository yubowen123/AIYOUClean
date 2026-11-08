import Foundation
import AppKit
import Darwin

public struct LiveMetrics: Codable,Sendable {
    public let timestamp:Date
    public let cpuPercent:Double?
    public let memoryUsed:UInt64
    public let memoryTotal:UInt64
    public let memoryPressure:String
    public let networkReceivedPerSecond:Double?
    public let networkSentPerSecond:Double?
    public let swapUsage:String
    public let notices:[String]
}
public final class MetricsSampler:@unchecked Sendable {
    private var previousCPU:(UInt64,UInt64)?
    private var previousNetwork:(UInt64,UInt64,Date)?
    private let lock=NSLock()
    public init(){}
    public func sample()->LiveMetrics {
        lock.lock();defer{lock.unlock()}
        var cpu=host_cpu_load_info();var cpuCount=mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size/MemoryLayout<integer_t>.size)
        let cpuResult=withUnsafeMutablePointer(to:&cpu) {p in p.withMemoryRebound(to:integer_t.self,capacity:Int(cpuCount)){host_statistics(mach_host_self(),HOST_CPU_LOAD_INFO,$0,&cpuCount)}}
        var percent:Double?
        if cpuResult == KERN_SUCCESS {
            let ticks=cpu.cpu_ticks;let busy=UInt64(ticks.0)+UInt64(ticks.1)+UInt64(ticks.3);let idle=UInt64(ticks.2)
            if let old=previousCPU,busy>=old.0,idle>=old.1 {let delta=(busy-old.0)+(idle-old.1);if delta>0 {percent=100*Double(busy-old.0)/Double(delta)}}
            previousCPU=(busy,idle)
        }
        var vm=vm_statistics64();var count=mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size/MemoryLayout<integer_t>.size)
        let vmResult=withUnsafeMutablePointer(to:&vm){p in p.withMemoryRebound(to:integer_t.self,capacity:Int(count)){host_statistics64(mach_host_self(),HOST_VM_INFO64,$0,&count)}}
        let total=ProcessInfo.processInfo.physicalMemory
        let used=vmResult == KERN_SUCCESS ? min(total,(UInt64(vm.active_count)+UInt64(vm.wire_count)+UInt64(vm.compressor_page_count))*UInt64(vm_kernel_page_size)) : 0
        let pressureResult=CommandRunner.run("/usr/sbin/sysctl",["-n","kern.memorystatus_vm_pressure_level"],timeout:2)
        let level=Int(pressureResult.output.trimmingCharacters(in:.whitespacesAndNewlines))
        let pressure=level.map { $0 == 1 ? "正常" : ($0 == 2 ? "警告" : ($0 == 4 ? "紧张" : "未知")) } ?? "未知"
        var received:UInt64=0;var sent:UInt64=0;var addresses:UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&addresses) == 0 {var current=addresses;while let ptr=current {let item=ptr.pointee;if let address=item.ifa_addr,address.pointee.sa_family == UInt8(AF_LINK),(item.ifa_flags & UInt32(IFF_LOOPBACK)) == 0,let data=item.ifa_data {let info=data.assumingMemoryBound(to:if_data.self).pointee;received+=UInt64(info.ifi_ibytes);sent+=UInt64(info.ifi_obytes)};current=item.ifa_next};freeifaddrs(addresses)}
        let now=Date();var download:Double?;var upload:Double?
        if let old=previousNetwork {let elapsed=now.timeIntervalSince(old.2);if elapsed>0,received>=old.0,sent>=old.1 {download=Double(received-old.0)/elapsed;upload=Double(sent-old.1)/elapsed}}
        previousNetwork=(received,sent,now)
        let swap=CommandRunner.run("/usr/sbin/sysctl",["-n","vm.swapusage"],timeout:2).output.trimmingCharacters(in:.whitespacesAndNewlines)
        var notices:[String]=[]
        if let percent,percent>90 {notices.append("CPU 持续采样值高于90%，可检查正在运行的应用。")}
        if pressure == "警告" || pressure == "紧张" {notices.append("系统内存压力为\(pressure)。")}
        return LiveMetrics(timestamp:now,cpuPercent:percent,memoryUsed:used,memoryTotal:total,memoryPressure:pressure,networkReceivedPerSecond:download,networkSentPerSecond:upload,swapUsage:swap,notices:notices)
    }
}
public struct RunningProcessInfo:Identifiable,Sendable {public let id:Int32;public let name:String;public let cpu:Double;public let memoryKB:Int64}
public enum ProcessMonitor {
    public static func list()->[RunningProcessInfo] {
        let r=CommandRunner.run("/bin/ps",["-axo","pid=,pcpu=,rss=,comm="],timeout:8)
        guard r.code == 0 else{return []}
        return r.output.split(separator:"\n").compactMap {line in
            let parts=line.split(maxSplits:3,whereSeparator:{$0 == " " || $0 == "\t"});guard parts.count==4,let pid=Int32(parts[0]),let cpu=Double(parts[1]),let mem=Int64(parts[2]) else{return nil}
            return RunningProcessInfo(id:pid,name:String(parts[3]),cpu:cpu,memoryKB:mem)
        }.sorted {$0.cpu>$1.cpu}
    }
    public static func terminateApp(pid:Int32,confirmed:Bool)->Bool {
        guard confirmed,pid != ProcessInfo.processInfo.processIdentifier,let app=NSRunningApplication(processIdentifier:pid) else{return false}
        return app.terminate() // Graceful terminate, not SIGKILL; app may present save dialogs.
    }
}
