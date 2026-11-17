import Foundation
import UIKit

@MainActor enum DeviceSampling {
  static func take() -> ResourceSnapshot {
    let device = UIDevice.current
    let info = ProcessInfo.processInfo
    let thermal =
      switch info.thermalState {
      case .nominal: "nominal"
      case .fair: "fair"
      case .serious: "serious"
      case .critical: "critical"
      @unknown default: "unknown"
      }
    let battery =
      switch device.batteryState {
      case .unknown: "unknown"
      case .unplugged: "unplugged"
      case .charging: "charging"
      case .full: "full"
      @unknown default: "unknown"
      }
    let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
      .first { $0.activationState == .foregroundActive }
    return ResourceSnapshot(
      thermal: thermal,
      batteryLevel: device.batteryLevel >= 0 ? Double(device.batteryLevel) : nil,
      batteryState: battery, lowPowerMode: info.isLowPowerModeEnabled,
      footprintBytes: footprint(), foreground: UIApplication.shared.applicationState == .active,
      brightness: scene.map { Double($0.screen.brightness) })
  }

  private static func footprint() -> UInt64? {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size) / 4
    let result = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
      }
    }
    return result == KERN_SUCCESS ? info.phys_footprint : nil
  }
}
