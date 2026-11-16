import Darwin
import Foundation
import IOKit
import IOKit.ps

/// Raw per-core CPU tick counters (they only ever grow, and wrap at 2^32).
struct CPUTicks: Equatable {
    var user: UInt32
    var system: UInt32
    var idle: UInt32
    var nice: UInt32
}

/// Reads the Mac's vitals from the same kernel counters Activity Monitor uses.
/// Rates (CPU, network, per-process CPU) are differences between two samples,
/// so the first sample after a pause primes the counters.
actor SystemSampler {
    private let host = mach_host_self()
    private let timebase: mach_timebase_info_data_t
    private var previousDate: Date?
    private var previousTicks: [CPUTicks] = []
    private var previousNetwork: [String: (in: UInt32, out: UInt32)] = [:]
    private var previousProcessTime: [Int32: UInt64] = [:]
    private var names: [Int32: String] = [:]
    private var batteryDetails: (cycles: Int?, health: Double?, read: Date)?

    init() {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        timebase = tb
    }

    /// Forget previous counters (after a pause, so rates aren't averaged over the gap).
    func reset() {
        previousDate = nil
        previousTicks = []
        previousNetwork = [:]
        previousProcessTime = [:]
    }

    func sample() -> SystemSnapshot {
        let now = Date()
        let elapsed = previousDate.map { now.timeIntervalSince($0) } ?? 0
        previousDate = now

        let ticks = readCPUTicks()
        let cpu = Self.cpuUsage(previous: previousTicks, current: ticks)
        previousTicks = ticks

        let network = readNetworkCounters()
        var bytesIn = 0.0, bytesOut = 0.0
        if elapsed > 0 {
            for (name, now) in network {
                guard let before = previousNetwork[name] else { continue }
                bytesIn += Self.rate(previous: before.in, current: now.in, seconds: elapsed)
                bytesOut += Self.rate(previous: before.out, current: now.out, seconds: elapsed)
            }
        }
        previousNetwork = network

        var loads = [Double](repeating: 0, count: 3)
        getloadavg(&loads, 3)

        return SystemSnapshot(
            date: now,
            cpu: cpu.total,
            cpuPerCore: cpu.perCore,
            loadAverage: loads,
            memory: readMemory(),
            memoryPressure: MemoryPressure(rawValue: Int(Self.sysctlInt32("kern.memorystatus_vm_pressure_level") ?? 1)) ?? .normal,
            disk: readDisk(),
            battery: readBattery(),
            networkIn: bytesIn,
            networkOut: bytesOut,
            processes: readProcesses(elapsed: elapsed),
            thermal: ThermalLevel(ProcessInfo.processInfo.thermalState),
            uptime: ProcessInfo.processInfo.systemUptime
        )
    }

    // MARK: Pure math (unit tested)

    /// CPU busy fraction overall and per core between two tick readings.
    /// With no previous reading, this is the average since boot.
    static func cpuUsage(previous: [CPUTicks], current: [CPUTicks]) -> (total: Double, perCore: [Double]) {
        var busyAll = 0.0, totalAll = 0.0
        var perCore: [Double] = []
        for (i, now) in current.enumerated() {
            let before = i < previous.count ? previous[i] : CPUTicks(user: 0, system: 0, idle: 0, nice: 0)
            let busy = Double(now.user &- before.user) + Double(now.system &- before.system) + Double(now.nice &- before.nice)
            let total = busy + Double(now.idle &- before.idle)
            perCore.append(total > 0 ? busy / total : 0)
            busyAll += busy
            totalAll += total
        }
        return (totalAll > 0 ? busyAll / totalAll : 0, perCore)
    }

    /// Bytes per second from two readings of a 32-bit counter that may have wrapped.
    static func rate(previous: UInt32, current: UInt32, seconds: Double) -> Double {
        seconds > 0 ? Double(current &- previous) / seconds : 0
    }

    static func memoryUsage(stats: vm_statistics64, pageSize: UInt64, total: UInt64, swapUsed: UInt64) -> MemoryUsage {
        let internalPages = UInt64(stats.internal_page_count)
        let purgeable = UInt64(stats.purgeable_count)
        return MemoryUsage(
            total: total,
            app: (internalPages > purgeable ? internalPages - purgeable : 0) * pageSize,
            wired: UInt64(stats.wire_count) * pageSize,
            compressed: UInt64(stats.compressor_page_count) * pageSize,
            cached: (UInt64(stats.external_page_count) + purgeable) * pageSize,
            swapUsed: swapUsed
        )
    }

    // MARK: Readers

    private func readCPUTicks() -> [CPUTicks] {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount) == KERN_SUCCESS,
              let info else { return [] }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }
        return (0..<Int(cpuCount)).map { cpu in
            let base = cpu * Int(CPU_STATE_MAX)
            func ticks(_ state: Int32) -> UInt32 { UInt32(bitPattern: info[base + Int(state)]) }
            return CPUTicks(user: ticks(CPU_STATE_USER), system: ticks(CPU_STATE_SYSTEM),
                            idle: ticks(CPU_STATE_IDLE), nice: ticks(CPU_STATE_NICE))
        }
    }

    private func readMemory() -> MemoryUsage {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(host, HOST_VM_INFO64, $0, &count) }
        }
        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        let swapUsed: UInt64 = sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0 ? swap.xsu_used : 0
        let total = ProcessInfo.processInfo.physicalMemory
        guard result == KERN_SUCCESS else {
            return MemoryUsage(total: total, app: 0, wired: 0, compressed: 0, cached: 0, swapUsed: swapUsed)
        }
        return Self.memoryUsage(stats: stats, pageSize: UInt64(getpagesize()), total: total, swapUsed: swapUsed)
    }

    private func readDisk() -> DiskUsage {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys)
        return DiskUsage(total: UInt64(max(0, values?.volumeTotalCapacity ?? 0)),
                         available: UInt64(max(0, values?.volumeAvailableCapacityForImportantUsage ?? 0)))
    }

    private func readBattery() -> BatteryInfo? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            guard let d = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            let current = d[kIOPSCurrentCapacityKey] as? Int ?? 0
            let max = d[kIOPSMaxCapacityKey] as? Int ?? 100
            let charging = d[kIOPSIsChargingKey] as? Bool ?? false
            let minutes = (charging ? d[kIOPSTimeToFullChargeKey] : d[kIOPSTimeToEmptyKey]) as? Int
            let details = batteryCycleAndHealth()
            return BatteryInfo(
                level: max > 0 ? Double(current) / Double(max) : 0,
                isCharging: charging,
                onACPower: d[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue,
                minutesRemaining: (minutes ?? -1) > 0 ? minutes : nil,
                cycleCount: details.cycles,
                health: details.health
            )
        }
        return nil
    }

    /// Cycle count and health change slowly; read them at most once a minute.
    private func batteryCycleAndHealth() -> (cycles: Int?, health: Double?) {
        if let cached = batteryDetails, Date().timeIntervalSince(cached.read) < 60 { return (cached.cycles, cached.health) }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return (nil, nil) }
        defer { IOObjectRelease(service) }
        func int(_ key: String) -> Int? {
            IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Int
        }
        let cycles = int("CycleCount")
        let health: Double? = {
            guard let raw = int("AppleRawMaxCapacity"), let design = int("DesignCapacity"), design > 0 else { return nil }
            return min(1, Double(raw) / Double(design))
        }()
        batteryDetails = (cycles, health, Date())
        return (cycles, health)
    }

    /// Byte counters for physical interfaces (Wi-Fi/Ethernet "en*", cellular "pdp_ip*").
    /// VPN tunnels (utun, ipsec) are skipped: their traffic also crosses en*, so
    /// counting both would double it.
    private func readNetworkCounters() -> [String: (in: UInt32, out: UInt32)] {
        var result: [String: (in: UInt32, out: UInt32)] = [:]
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0, let first = addresses else { return [:] }
        defer { freeifaddrs(addresses) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = pointer.pointee
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK), let data = ifa.ifa_data else { continue }
            let name = String(cString: ifa.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("pdp_ip") else { continue }
            let counters = data.assumingMemoryBound(to: if_data.self).pointee
            result[name] = (counters.ifi_ibytes, counters.ifi_obytes)
        }
        return result
    }

    /// CPU and memory for every process macOS lets us inspect (your own; others need root).
    /// Keeps the top 25 by CPU plus the top 25 by memory.
    private func readProcesses(elapsed: TimeInterval) -> [ProcessUsage] {
        let capacity = Int(proc_listallpids(nil, 0)) + 64
        guard capacity > 64 else { return [] }
        var pids = [pid_t](repeating: 0, count: capacity)
        let count = pids.withUnsafeMutableBytes { Int(proc_listallpids($0.baseAddress, Int32($0.count))) }

        var times: [Int32: UInt64] = [:]
        var raw: [(pid: Int32, cpu: Double, memory: UInt64)] = []
        for pid in pids.prefix(max(0, count)) where pid > 0 {
            var info = rusage_info_v2()
            let status = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
            }
            guard status == 0 else { continue }
            let cpuTime = (info.ri_user_time + info.ri_system_time) * UInt64(timebase.numer) / UInt64(max(1, timebase.denom))
            times[pid] = cpuTime
            var percent = 0.0
            if elapsed > 0, let before = previousProcessTime[pid], cpuTime >= before {
                percent = Double(cpuTime - before) / (elapsed * 1_000_000_000) * 100
            }
            raw.append((pid, percent, info.ri_phys_footprint))
        }
        previousProcessTime = times
        names = names.filter { times[$0.key] != nil }

        let byCPU = raw.sorted { $0.cpu > $1.cpu }.prefix(25)
        let byMemory = raw.sorted { $0.memory > $1.memory }.prefix(25)
        var seen = Set<Int32>()
        return (byCPU + byMemory).compactMap { p in
            guard seen.insert(p.pid).inserted else { return nil }
            return ProcessUsage(pid: p.pid, name: name(of: p.pid), cpuPercent: p.cpu, memoryBytes: p.memory)
        }
    }

    /// The executable's file name (full length); the kernel's short process
    /// name is cut off at 32 characters, e.g. "Google Chrome Helper (Aperitif".
    private func name(of pid: Int32) -> String {
        if let cached = names[pid] { return cached }
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        var name = proc_pidpath(pid, &path, UInt32(path.count)) > 0 ? (String(cString: path) as NSString).lastPathComponent : ""
        if name.isEmpty {
            var buffer = [CChar](repeating: 0, count: 256)
            if proc_name(pid, &buffer, UInt32(buffer.count)) > 0 { name = String(cString: buffer) }
        }
        if name.isEmpty { name = "pid \(pid)" }
        names[pid] = name
        return name
    }

    // MARK: sysctl helpers

    static func sysctlString(_ key: String) -> String? {
        var size = 0
        guard sysctlbyname(key, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(key, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    static func sysctlInt32(_ key: String) -> Int32? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname(key, &value, &size, nil, 0) == 0 ? value : nil
    }
}
