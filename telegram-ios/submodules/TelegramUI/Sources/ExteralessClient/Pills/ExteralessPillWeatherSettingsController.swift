import AccountContext
import ExteralessCore
import Foundation
import UIKit

final class ExteralessPillWeatherSettingsController: ExteralessPillTableController {
    private var location: ExteralessPillLocation?
    private var locationStatus: String?
    init(context: AccountContext) {
        super.init(context: context, title: "Weather")
        self.settingsChanged = { [weak self] in self?.render() }
        self.accountInvalidated = { [weak self] in self?.location?.cancel(); self?.location = nil }
        self.refreshAction = { [weak self] in self?.render(); self?.tableView.refreshControl?.endRefreshing() }
        self.render()
    }
    required init(coder aDecoder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewWillDisappear(_ animated: Bool) {
        self.location?.cancel(); self.location = nil
        super.viewWillDisappear(animated)
    }
    private func render() {
        guard self.accountIsValid else { return }
        let config = try? self.pillRuntime.configuration()
        let current = config?.usesCurrentLocation ?? true
        let source = ClientSettings.shared.string("pills.weatherProvider", default: "telegram")
        let units = ClientSettings.shared.string("pills.weatherUnits", default: "AUTO")
        let coordinate = config?.coordinate
        let address = config?.string("weatherAddress") ?? ""
        self.sections = [.init(title: "Location", footer: self.locationStatus ?? "Location permission is requested only by Enable current location. A selected weather pill uses one approximate fix, stops on exit/background, and refreshes no more often than every 15 minutes.", rows: [
            .init(id: "pills.weather.current", title: "Enable current location", checked: current, action: { [weak self] in self?.enableCurrentLocation() }),
            .init(id: "pills.weather.map", title: "Choose on map", detail: address.isEmpty ? coordinate.map { String(format: "%.4f, %.4f", $0.latitude, $0.longitude) } ?? "No manual location" : address, checked: !current, action: { [weak self] in guard let self else { return }; self.pushChild(ExteralessPillMapController(context: self.context)) }),
            .init(id: "pills.weather.manual", title: "Enter coordinates", action: { [weak self] in self?.manualCoordinates() }),
            .init(id: "pills.weather.permissions", title: "Open app location settings", action: { [weak self] in
                guard self?.accountIsValid == true, let url = URL(string: UIApplication.openSettingsURLString) else { return }
                UIApplication.shared.open(url)
            })
        ]), .init(title: "Source", footer: "Telegram weather bot is the active Android implementation. Open-Meteo uses its preserved HTTP endpoint. Both send the selected coordinates only while Weather is visible; neither requires a service API key.", rows: [
            .init(id: "pills.weather.telegram", title: "Telegram weather bot", checked: source == "telegram", action: { [weak self] in self?.set("pills.weatherProvider", value: "telegram") }),
            .init(id: "pills.weather.openMeteo", title: "Open-Meteo", checked: source == "openMeteo", action: { [weak self] in self?.set("pills.weatherProvider", value: "openMeteo") })
        ]), .init(title: "Units", rows: ["AUTO", "C", "F"].map { value in
            .init(id: "pills.weather.units.\(value)", title: value == "AUTO" ? "Automatic (original time-zone rule)" : value == "C" ? "Celsius" : "Fahrenheit", checked: value == units, action: { [weak self] in self?.set("pills.weatherUnits", value: value) })
        })]
        self.reloadRows()
    }
    private func set(_ key: String, value: String) {
        self.writePillSettings({ try ClientSettings.shared.applyPublic([key: .string(value)]) }, completion: { [weak self] in self?.render() })
    }
    private func enableCurrentLocation() {
        self.location?.cancel()
        let location = ExteralessPillLocation(); self.location = location
        self.locationStatus = "Waiting for a location…"; self.render()
        location.request(explicitAuthorization: true) { [weak self] result in
            guard let self, self.accountIsValid, self.pillRuntime.lease.isValid, self.screenIsVisible else { return }
            switch result {
            case .success:
                self.locationStatus = "Current approximate location is available."
                self.writePillSettings({ try ClientSettings.shared.applyPublic(["chats.weatherUseCurrentLocation": .bool(true)]) }, completion: { [weak self] in self?.render() })
            case let .failure(error):
                switch error.reason {
                case .denied: self.locationStatus = "Location permission is denied. Choose manual coordinates or open app settings."
                case .needsPermission: self.locationStatus = "Location permission has not been granted."
                case .timeout: self.locationStatus = "The location request timed out. Try again or choose a manual location."
                case .unavailable: self.locationStatus = "Location services are unavailable. A manual location is supported."
                }
                self.render()
            }
        }
    }
    private func manualCoordinates() {
        let alert = UIAlertController(title: "Weather location", message: "Latitude −90…90; longitude −180…180. Coordinates and name are saved together.", preferredStyle: .alert)
        alert.addTextField { field in field.placeholder = "Latitude"; field.text = ClientSettings.shared.string("chats.weatherLatitude"); field.keyboardType = .numbersAndPunctuation }
        alert.addTextField { field in field.placeholder = "Longitude"; field.text = ClientSettings.shared.string("chats.weatherLongitude"); field.keyboardType = .numbersAndPunctuation }
        alert.addTextField { field in field.placeholder = "Location name (optional)"; field.text = ClientSettings.shared.string("chats.weatherAddress") }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Save", style: .default) { [weak self, weak alert] _ in
            guard let self, let fields = alert?.textFields, fields.count == 3,
                  let latitude = Double(fields[0].text ?? ""), let longitude = Double(fields[1].text ?? ""),
                  let coordinate = try? PillCoordinate(latitude: latitude, longitude: longitude) else { self?.displayError("Enter valid latitude and longitude."); return }
            let address = fields[2].text ?? ""; let store = self.pillRuntime.store
            self.writePillSettings({ try store.setWeather(coordinate: coordinate, address: address) }, completion: { [weak self] in self?.render() })
        })
        self.context.sharedContext.applicationBindings.presentNativeController(alert)
    }
}
