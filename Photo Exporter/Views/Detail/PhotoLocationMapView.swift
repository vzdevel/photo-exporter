//
//  PhotoLocationMapView.swift
//  Photo Exporter
//

import SwiftUI
import MapKit

struct PhotoLocationMapView: View {
    let location: CLLocation
    let address: String?
    var isGPSAdjusted: Bool = false
    let onOpenInMaps: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "mappin.and.ellipse")
                    .font(.caption.weight(.bold))
                    .foregroundColor(.red)

                Text("Location")
                    .font(.caption.weight(.bold))
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)

                Spacer()

                if isGPSAdjusted {
                    StatusBadgeView(type: .adjustedGPS)
                }

                Button(action: onOpenInMaps) {
                    HStack(spacing: 4) {
                        Text("Open in Maps")
                            .font(.caption.weight(.semibold))
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 9, weight: .bold))
                    }
                    .foregroundColor(.blue)
                }
            }

            // Map preview with pin
            LocationMapViewRepresentable(coordinate: location.coordinate)
                .frame(height: 180)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .contentShape(Rectangle())
                .onTapGesture {
                    onOpenInMaps()
                }

            // Address and coordinates
            VStack(alignment: .leading, spacing: 4) {
                if let address = address, !address.isEmpty {
                    Text(address)
                        .font(.system(.subheadline, design: .rounded, weight: .semibold))
                        .foregroundColor(.primary)
                }

                Text(String(format: "%.5f°, %.5f° • Alt: %.0fm", location.coordinate.latitude, location.coordinate.longitude, location.altitude))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(16)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(14)
        .padding(.horizontal, 16)
    }
}

fileprivate struct LocationMapViewRepresentable: UIViewRepresentable {
    let coordinate: CLLocationCoordinate2D

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator: NSObject, MKMapViewDelegate {
        var lastCoordinate: CLLocationCoordinate2D?

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard !(annotation is MKUserLocation) else { return nil }
            let identifier = "PhotoLocationPin"
            var view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier) as? MKMarkerAnnotationView
            if view == nil {
                view = MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: identifier)
                view?.markerTintColor = .systemRed
            } else {
                view?.annotation = annotation
            }
            return view
        }
    }

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        mapView.isScrollEnabled = false
        mapView.isZoomEnabled = false
        mapView.isPitchEnabled = false
        mapView.isRotateEnabled = false
        mapView.layer.cornerRadius = 12
        mapView.clipsToBounds = true

        let region = MKCoordinateRegion(
            center: coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.015, longitudeDelta: 0.015)
        )
        mapView.setRegion(region, animated: false)

        let pin = MKPointAnnotation()
        pin.coordinate = coordinate
        mapView.addAnnotation(pin)
        context.coordinator.lastCoordinate = coordinate

        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        if let last = context.coordinator.lastCoordinate {
            let latDiff = abs(last.latitude - coordinate.latitude)
            let lonDiff = abs(last.longitude - coordinate.longitude)
            if latDiff < 0.0001 && lonDiff < 0.0001 {
                // Same location: do nothing to prevent any tile reload or flicker
                return
            }
        }

        context.coordinator.lastCoordinate = coordinate

        mapView.removeAnnotations(mapView.annotations)
        let pin = MKPointAnnotation()
        pin.coordinate = coordinate
        mapView.addAnnotation(pin)

        let newRegion = MKCoordinateRegion(
            center: coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.015, longitudeDelta: 0.015)
        )
        mapView.setRegion(newRegion, animated: true)
    }
}
