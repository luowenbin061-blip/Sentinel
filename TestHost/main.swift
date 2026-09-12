import UIKit
import Darwin

// ===== 顶层代码（main.swift）：最早执行，先加载插件再启动 App =====
// 真机上由 TrollFools 注入加载；模拟器里用 dlopen 等效模拟。
let _dylibPath = Bundle.main.bundlePath + "/Sentinel_sim.dylib"
let _handle = dlopen(_dylibPath, RTLD_NOW)
FileHandle.standardError.write(Data("dlopen(\(_dylibPath)) → \(_handle != nil ? "OK" : "FAILED")\n".utf8))

// ===== 最小宿主：只要有一个能 present 的 rootViewController 就够 =====
// 哨兵的自测自带假 HUD 图，不依赖宿主界面内容。
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let win = UIWindow(frame: UIScreen.main.bounds)
        let vc = UIViewController()
        vc.view.backgroundColor = UIColor(red: 0.11, green: 0.13, blue: 0.18, alpha: 1)

        let lb = UILabel(frame: CGRect(x: 0, y: 380, width: UIScreen.main.bounds.width, height: 60))
        lb.text = "哨兵测试宿主"
        lb.textAlignment = .center
        lb.textColor = .white
        lb.font = .boldSystemFont(ofSize: 20)
        vc.view.addSubview(lb)

        win.rootViewController = vc
        win.makeKeyAndVisible()
        self.window = win
        FileHandle.standardError.write(Data("[TestHost] HOST_READY\n".utf8))
        return true
    }
}

UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(AppDelegate.self))
