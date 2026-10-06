import Foundation
import QingYiCore
import ServiceManagement

enum LaunchAtLogin {
    static var isAvailable: Bool { AppInfo.isBundled }

    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func apply(_ enabled: Bool) {
        guard isAvailable else { return }
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            Log.error("设置登录时启动失败", error)
        }
    }
}
