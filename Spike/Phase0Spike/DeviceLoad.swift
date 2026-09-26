import Foundation

#if canImport(UIKit)
  import UIKit
#endif

// P0-14: what a sustained agent workload costs. Samples thermal state, battery and memory around
// each multi-step run, so latency can be read against the thermal state it was measured in.
// Battery drain is only meaningful untethered: a cable charges the device while it runs.

/// One sample of device condition, taken between runs.
struct DeviceSample: Sendable {
  let thermal: String
  let batteryLevel: Float
  let batteryState: String
  let lowPowerMode: Bool
  let footprintMB: Double

  static func take() -> DeviceSample {
    let info = ProcessInfo.processInfo
    let thermal =
      switch info.thermalState {
      case .nominal: "nominal"
      case .fair: "fair"
      case .serious: "serious"
      case .critical: "critical"
      @unknown default: "unknown"
      }
    var level: Float = -1
    var state = "n/a"
    #if canImport(UIKit)
      let device = UIDevice.current
      level = device.batteryLevel
      state =
        switch device.batteryState {
        case .unknown: "unknown"
        case .unplugged: "unplugged"
        case .charging: "charging"
        case .full: "full"
        @unknown default: "unknown"
        }
    #endif
    return DeviceSample(
      thermal: thermal, batteryLevel: level, batteryState: state,
      lowPowerMode: info.isLowPowerModeEnabled, footprintMB: Self.footprintMB())
  }

  /// Resident memory as the OS accounts it (the number that gets an app jetsammed).
  private static func footprintMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size) / 4
    let result = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
      }
    }
    return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
  }

  var line: String {
    "thermal=\(thermal) battery=\(batteryLevel < 0 ? "n/a" : String(format: "%.0f%%", batteryLevel * 100)) "
      + "batteryState=\(batteryState) lowPower=\(lowPowerMode) "
      + "footprintMB=\(String(format: "%.1f", footprintMB))"
  }
}

/// Mirrors the run log into the app's Documents directory, so an untethered run survives the
/// console being disconnected and can be copied off afterwards with `devicectl device copy from`.
@MainActor
final class DeviceLogFile {
  private let handle: FileHandle?
  let url: URL?

  init(name: String) {
    let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    guard let target = directory?.appendingPathComponent(name) else {
      handle = nil
      url = nil
      return
    }
    FileManager.default.createFile(atPath: target.path, contents: nil)
    handle = try? FileHandle(forWritingTo: target)
    url = target
  }

  func write(_ line: String) {
    guard let handle else { return }
    try? handle.write(contentsOf: Data((line + "\n").utf8))
  }
}

extension FileManager {
  fileprivate func createFile(atPath path: String, contents: Data?) {
    if !fileExists(atPath: path) { createFile(atPath: path, contents: contents, attributes: nil) }
  }
}
