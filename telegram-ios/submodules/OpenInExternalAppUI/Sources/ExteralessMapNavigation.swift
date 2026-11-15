import ExteralessCore
import Foundation

/// Called only by the Google Maps action. MapKit/Yandex/OSM and Telegram media
/// keep the original immutable WGS84 point; no geolocation permission is needed.
func exteralessGoogleMapCoordinate(latitude: Double, longitude: Double) -> (Double, Double)? {
    guard let coordinate = MapCoordinate(latitude: latitude, longitude: longitude) else { return nil }
    let result = MapPolicy.current().googleCoordinate(coordinate)
    return (result.latitude, result.longitude)
}

func exteralessOpenStreetMapOption(latitude: Double, longitude: Double) -> OpenInOption? {
    guard MapPolicy.current().useOpenStreetMap, let coordinate = MapCoordinate(latitude: latitude, longitude: longitude), let url = MapProviderURL.openStreetMap(coordinate: coordinate) else { return nil }
    return OpenInOption(identifier: "openStreetMap", application: .other(title: "OpenStreetMap", identifier: 0, scheme: "https", store: nil), action: { .openUrl(url: url.absoluteString) })
}
