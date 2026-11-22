//
//  GeocodingService.swift
//  Photo Exporter
//

import Foundation
import CoreLocation

/// Service for reverse-geocoding coordinates to human-readable addresses
final class GeocodingService {
    static let shared = GeocodingService()

    private let geocoder = CLGeocoder()
    private var cache: [String: String] = [:]

    private init() {}

    func reverseGeocode(location: CLLocation) async -> String {
        let key = String(format: "%.4f,%.4f", location.coordinate.latitude, location.coordinate.longitude)
        if let cached = cache[key] {
            return cached
        }

        do {
            let placemarks = try await geocoder.reverseGeocodeLocation(location)
            guard let placemark = placemarks.first else {
                return "Unknown Location"
            }

            var components: [String] = []
            if let name = placemark.name, name != placemark.locality {
                components.append(name)
            }
            if let locality = placemark.locality {
                components.append(locality)
            }
            if let adminArea = placemark.administrativeArea {
                components.append(adminArea)
            }
            if let country = placemark.country {
                components.append(country)
            }

            let result = components.isEmpty ? "Unknown Location" : components.joined(separator: ", ")
            cache[key] = result
            return result
        } catch {
            return String(format: "%.4f°, %.4f°", location.coordinate.latitude, location.coordinate.longitude)
        }
    }
}
