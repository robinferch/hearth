import CarPlay
import HearthPlayback

/// CarPlay scene (referenced from Info.plist as `$(PRODUCT_MODULE_NAME).CarPlaySceneDelegate`).
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var controller: CarPlayController?

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene, didConnect interfaceController: CPInterfaceController) {
        // CarPlay can launch the app without a phone UI.
        AppLifecycle.shared.launch()
        let controller = CarPlayController(interface: interfaceController)
        self.controller = controller
        controller.connect()
    }

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene, didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        controller?.disconnect()
        controller = nil
    }
}
