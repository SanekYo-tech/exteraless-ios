import CoreLocation
import ExteralessCore
import Foundation
import UIKit

/// One coarse, time-bounded native location fix. Authorization is requested only by an explicit UI action.
@MainActor final class ExteralessPillLocation: NSObject, @preconcurrency CLLocationManagerDelegate {
    enum Failure: Sendable { case needsPermission, denied, unavailable, timeout }
    private let manager = CLLocationManager()
    private var completion: ((Result<PillCoordinate, FailureError>) -> Void)?
    private var timeout: Timer?
    private var authorizationAction = false
    private var backgroundObserver: NSObjectProtocol?
    struct FailureError: Error, Sendable { let reason: Failure }

    override init() {
        super.init()
        self.manager.delegate = self
        self.manager.desiredAccuracy = kCLLocationAccuracyKilometer
        self.manager.distanceFilter = 1000
        self.backgroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish(.failure(.init(reason: .unavailable))) }
        }
    }
    deinit { if let observer = self.backgroundObserver { NotificationCenter.default.removeObserver(observer) } }
    var authorization: CLAuthorizationStatus { self.manager.authorizationStatus }

    func request(explicitAuthorization: Bool, completion: @escaping (Result<PillCoordinate, FailureError>) -> Void) {
        self.cancel()
        self.completion = completion
        self.authorizationAction = explicitAuthorization
        self.timeout = Timer.scheduledTimer(withTimeInterval: 12, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish(.failure(.init(reason: .timeout))) }
        }
        self.timeout?.tolerance = 1
        self.continueRequest()
    }
    private func continueRequest() {
        guard self.completion != nil else { return }
        switch self.manager.authorizationStatus {
        case .notDetermined:
            guard self.authorizationAction else { self.finish(.failure(.init(reason: .needsPermission))); return }
            self.authorizationAction = false
            self.manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            self.authorizationAction = false
            if let location = self.manager.location, self.isUsable(location) {
                self.accept(location)
            } else {
                self.manager.requestLocation()
            }
        case .denied, .restricted: self.finish(.failure(.init(reason: .denied)))
        @unknown default: self.finish(.failure(.init(reason: .unavailable)))
        }
    }
    private func isUsable(_ location: CLLocation) -> Bool {
        let age = Date().timeIntervalSince(location.timestamp)
        return location.horizontalAccuracy.isFinite && location.horizontalAccuracy >= 0 && location.horizontalAccuracy <= 20_000 && age >= 0 && age <= 300
    }
    private func accept(_ location: CLLocation) {
        guard self.isUsable(location), let coordinate = try? PillCoordinate(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude) else { return }
        self.finish(.success(coordinate))
    }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard self.completion != nil, manager.authorizationStatus != .notDetermined else { return }
        self.continueRequest()
    }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        if let location = locations.last(where: self.isUsable) { self.accept(location) }
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        self.finish(.failure(.init(reason: self.manager.authorizationStatus == .denied ? .denied : .unavailable)))
    }
    private func finish(_ result: Result<PillCoordinate, FailureError>) {
        let completion = self.completion
        self.cancel()
        completion?(result)
    }
    func cancel() {
        self.timeout?.invalidate(); self.timeout = nil
        self.completion = nil; self.authorizationAction = false
        self.manager.stopUpdatingLocation()
    }
}
