import Cocoa

@mainActor
main() {
	app = NSApplication()
	delegate = AppDelegate()
	app.delegate = delegate
	app.run(.accessory)
}