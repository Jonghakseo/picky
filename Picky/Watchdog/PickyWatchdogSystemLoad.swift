//
//  PickyWatchdogSystemLoad.swift
//  Picky
//
//  Cheap system-load snapshot recorded alongside watchdog spin samples so a
//  reader can tell "Picky hung" apart from "the whole machine was starved"
//  without re-running top/ps after the fact. Uses syscalls only — spawning a
//  process here would add load to an already struggling system.
//

import Darwin
import Foundation

struct PickyWatchdogSystemLoad: Equatable {
    var loadAverage1: Double
    var loadAverage5: Double
    var loadAverage15: Double
    var processorCount: Int
    var swapUsedBytes: UInt64
    var swapTotalBytes: UInt64

    static func current() -> PickyWatchdogSystemLoad {
        var averages = [Double](repeating: 0, count: 3)
        let sampled = getloadavg(&averages, 3)
        if sampled < 3 { averages = [Double](repeating: 0, count: 3) }

        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &size, nil, 0) != 0 {
            swap = xsw_usage()
        }

        return PickyWatchdogSystemLoad(
            loadAverage1: averages[0],
            loadAverage5: averages[1],
            loadAverage15: averages[2],
            processorCount: ProcessInfo.processInfo.activeProcessorCount,
            swapUsedBytes: swap.xsu_used,
            swapTotalBytes: swap.xsu_total
        )
    }

    /// Load average per core. Above ~1.0 the machine is oversubscribed, which
    /// makes an idle-looking main-thread sample expected rather than surprising.
    var loadPerCore: Double {
        processorCount > 0 ? loadAverage1 / Double(processorCount) : 0
    }

    var summaryLines: [String] {
        [
            String(
                format: "loadAverage: %.2f %.2f %.2f (cores %d, perCore %.2f)",
                loadAverage1, loadAverage5, loadAverage15, processorCount, loadPerCore
            ),
            String(
                format: "swap: %.0fM used / %.0fM total",
                Double(swapUsedBytes) / 1_048_576, Double(swapTotalBytes) / 1_048_576
            ),
        ]
    }
}
