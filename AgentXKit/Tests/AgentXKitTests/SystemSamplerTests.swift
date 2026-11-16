import Darwin
import Foundation
import Testing
@testable import AgentXKit

@Suite("System sampler math")
struct SystemSamplerMathTests {
    @Test func cpuUsageFromTickDeltas() {
        let before = [CPUTicks(user: 100, system: 50, idle: 850, nice: 0), CPUTicks(user: 0, system: 0, idle: 1000, nice: 0)]
        let after = [CPUTicks(user: 160, system: 70, idle: 870, nice: 0), CPUTicks(user: 0, system: 0, idle: 1100, nice: 0)]
        let usage = SystemSampler.cpuUsage(previous: before, current: after)
        #expect(abs(usage.perCore[0] - 0.8) < 0.0001)   // 80 busy of 100
        #expect(usage.perCore[1] == 0)
        #expect(abs(usage.total - 0.4) < 0.0001)        // 80 busy of 200
    }

    @Test func cpuTicksSurviveWraparound() {
        let before = [CPUTicks(user: UInt32.max - 9, system: 0, idle: 0, nice: 0)]
        let after = [CPUTicks(user: 10, system: 0, idle: 20, nice: 0)]
        let usage = SystemSampler.cpuUsage(previous: before, current: after)
        #expect(abs(usage.total - 20.0 / 40.0) < 0.0001)
    }

    @Test func networkRateHandlesCounterWrap() {
        #expect(SystemSampler.rate(previous: 1_000, current: 3_000, seconds: 2) == 1_000)
        #expect(SystemSampler.rate(previous: UInt32.max - 999, current: 1_000, seconds: 2) == 1_000)
        #expect(SystemSampler.rate(previous: 5, current: 10, seconds: 0) == 0)
    }

    @Test func memoryMatchesActivityMonitorFormula() {
        var stats = vm_statistics64()
        stats.internal_page_count = 1_000
        stats.purgeable_count = 100
        stats.wire_count = 200
        stats.compressor_page_count = 300
        stats.external_page_count = 400
        let m = SystemSampler.memoryUsage(stats: stats, pageSize: 16_384, total: 32 * 1_073_741_824, swapUsed: 0)
        #expect(m.app == 900 * 16_384)
        #expect(m.wired == 200 * 16_384)
        #expect(m.compressed == 300 * 16_384)
        #expect(m.used == 1_400 * 16_384)
        #expect(m.cached == 500 * 16_384)
    }
}

@Suite("System sampler on this Mac")
struct SystemSamplerLiveTests {
    @Test func readsSaneValues() async throws {
        let sampler = SystemSampler()
        _ = await sampler.sample()
        try await Task.sleep(for: .milliseconds(500))
        let s = await sampler.sample()

        #expect((0...1).contains(s.cpu))
        #expect(s.cpuPerCore.count == ProcessInfo.processInfo.activeProcessorCount)
        #expect(s.memory.total == ProcessInfo.processInfo.physicalMemory)
        #expect(s.memory.used > 0 && s.memory.used < s.memory.total)
        #expect(s.disk.total > 0 && s.disk.available <= s.disk.total)
        #expect(s.networkIn >= 0 && s.networkOut >= 0)
        #expect(!s.processes.isEmpty)
        #expect(s.processes.contains { $0.pid == getpid() })
        #expect(s.loadAverage.count == 3)

        // AGENTX_PRINT_SNAPSHOT=1 swift test ... prints the report for comparing with Activity Monitor.
        if ProcessInfo.processInfo.environment["AGENTX_PRINT_SNAPSHOT"] != nil {
            print("=== AgentX snapshot\n" + s.report(machine: .current()))
            try await Task.sleep(for: .seconds(2))
            let later = await sampler.sample()
            print("=== network over 2s: down \(Int(later.networkIn)) B/s, up \(Int(later.networkOut)) B/s")
        }
    }
}

@Suite("System report and monitor")
struct SystemReportTests {
    private func snapshot() -> SystemSnapshot {
        SystemSnapshot(
            date: Date(), cpu: 0.42, cpuPerCore: [0.5, 0.34], loadAverage: [2.5, 2.0, 1.5],
            memory: MemoryUsage(total: 16 << 30, app: 4 << 30, wired: 2 << 30, compressed: 6 << 30, cached: 1 << 30, swapUsed: 512 << 20),
            memoryPressure: .warning, disk: DiskUsage(total: 250 << 30, available: 25 << 30),
            battery: BatteryInfo(level: 0.8, isCharging: true, onACPower: true, minutesRemaining: 45, cycleCount: 173, health: 0.9),
            networkIn: 2048, networkOut: 0,
            processes: [ProcessUsage(pid: 10, name: "Busy", cpuPercent: 120, memoryBytes: 100 << 20),
                        ProcessUsage(pid: 11, name: "Hungry", cpuPercent: 1, memoryBytes: 3 << 30)],
            thermal: .fair, uptime: 3 * 86_400)
    }

    @Test func reportCoversEveryVital() {
        let text = snapshot().report(machine: MachineInfo(chip: "Apple M2", memory: 16 << 30, cores: 8, osVersion: "macOS 27.0"))
        #expect(text.contains("Apple M2"))
        #expect(text.contains("CPU: 42%"))
        #expect(text.contains("pressure elevated"))
        #expect(text.contains("Battery: 80%, charging"))
        #expect(text.contains("173 cycles"))
        #expect(text.contains("thermal state warm"))
        #expect(text.contains("Top processes by CPU: Busy (pid 10) 120% CPU"))
        #expect(text.contains("Top processes by memory: Hungry (pid 11)"))
        #expect(!text.contains("Zero"))
    }

    @Test func memoryUsedIsAppWiredCompressed() {
        let m = snapshot().memory
        #expect(m.used == 12 << 30)
        #expect(abs(m.usedFraction - 0.75) < 0.0001)
        #expect(m.free == 4 << 30)
    }

    @MainActor @Test func monitorSamplesOnlyWhileWatched() async throws {
        let monitor = SystemMonitor()
        #expect(monitor.latest == nil)
        monitor.beginWatching()
        for _ in 0..<40 where monitor.latest == nil { try await Task.sleep(for: .milliseconds(100)) }
        #expect(monitor.latest != nil)
        #expect(!monitor.history.isEmpty)
        monitor.endWatching()
        #expect(monitor.history.isEmpty)
    }
}
