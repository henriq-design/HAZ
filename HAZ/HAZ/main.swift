import Cocoa

// No storyboard: build the AppKit lifecycle explicitly so launch is reliable.
let launchUptime = ProcessInfo.processInfo.systemUptime
let application = NSApplication.shared
let appDelegate = AppDelegate(launchUptime: launchUptime)

application.delegate = appDelegate
application.setActivationPolicy(.accessory)
application.run()
