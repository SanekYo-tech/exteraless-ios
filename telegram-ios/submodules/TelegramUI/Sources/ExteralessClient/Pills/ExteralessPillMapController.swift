import AccountContext
import CoreLocation
import Display
import ExteralessCore
import MapKit
import UIKit

/// Manual map selection never starts Core Location or shows the device's location.
final class ExteralessPillMapController: ExteralessPillTableController {
    private let map = MKMapView()
    private var coordinate: PillCoordinate?
    init(context: AccountContext) {
        super.init(context: context, title: "Choose weather location")
        self.coordinate = (try? self.pillRuntime.configuration())?.coordinate
        self.map.showsUserLocation = false
        self.map.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(self.selectedPoint(_:))))
        if let coordinate = self.coordinate {
            self.map.setRegion(MKCoordinateRegion(center: .init(latitude: coordinate.latitude, longitude: coordinate.longitude), latitudinalMeters: 20_000, longitudinalMeters: 20_000), animated: false)
            self.showPin()
        } else { self.map.setVisibleMapRect(MKMapRect.world, animated: false) }
        self.refreshAction = { [weak self] in self?.render(); self?.tableView.refreshControl?.endRefreshing() }
        self.render()
    }
    required init(coder aDecoder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func loadDisplayNode() {
        super.loadDisplayNode()
        self.map.frame = CGRect(x: 0, y: 0, width: self.tableView.bounds.width, height: 240)
        self.tableView.tableHeaderView = self.map
    }
    override func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        self.map.frame = CGRect(x: 0, y: 0, width: self.tableView.bounds.width, height: 240)
        self.tableView.tableHeaderView = self.map
    }
    @objc private func selectedPoint(_ gesture: UITapGestureRecognizer) {
        guard self.accountIsValid else { return }
        let value = self.map.convert(gesture.location(in: self.map), toCoordinateFrom: self.map)
        self.coordinate = try? PillCoordinate(latitude: value.latitude, longitude: value.longitude)
        self.showPin(); self.render()
    }
    private func showPin() {
        self.map.removeAnnotations(self.map.annotations)
        if let coordinate = self.coordinate {
            let pin = MKPointAnnotation(); pin.coordinate = .init(latitude: coordinate.latitude, longitude: coordinate.longitude)
            self.map.addAnnotation(pin)
        }
    }
    private func render() {
        self.sections = [.init(footer: "Tap the map to choose a point. Map tiles use Apple's native map service only while this screen is opened. No device-location permission is needed.", rows: [
            .init(id: "pills.map.point", title: self.coordinate.map { String(format: "%.5f, %.5f", $0.latitude, $0.longitude) } ?? "Select a point", enabled: false),
            .init(id: "pills.map.save", title: "Use this weather location", enabled: self.coordinate != nil, action: { [weak self] in
                guard let self, let coordinate = self.coordinate else { return }; let store = self.pillRuntime.store
                self.writePillSettings({ try store.setWeather(coordinate: coordinate, address: "") }, completion: { [weak self] in self?.navigationController?.popViewController(animated: true) })
            })
        ])]
        self.reloadRows()
    }
}
