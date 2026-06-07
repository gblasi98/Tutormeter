import Foundation
import CoreLocation

// MARK: - Tutor Zone Model

/// Represents a Tutor/SICVE speed camera enforcement zone on an Italian highway.
///
/// A zone is defined by a start and end point on a specific highway,
/// with a direction of travel. The enforcement measures average speed
/// between the two points.
struct TutorZone: Codable, Identifiable, Equatable {
    /// Unique identifier (generated from highway + km markers).
    let id: String

    /// Highway name, e.g. "A1", "A4", "A14".
    let highway: String

    /// Human-readable description, e.g. "A1 Milano-Napoli, km 45-52 dir. Sud".
    let name: String

    /// Latitude of the zone start point.
    let startLat: Double

    /// Longitude of the zone start point.
    let startLon: Double

    /// Latitude of the zone end point.
    let endLat: Double

    /// Longitude of the zone end point.
    let endLon: Double

    /// Speed limit in km/h (typically 130, 110, or 90).
    let speedLimitKmh: Int

    /// Approximate length of the zone in meters.
    let lengthMeters: Double

    init(id: String, highway: String, name: String,
         startLat: Double, startLon: Double,
         endLat: Double, endLon: Double,
         speedLimitKmh: Int, lengthMeters: Double) {
        self.id = id
        self.highway = highway
        self.name = name
        self.startLat = startLat
        self.startLon = startLon
        self.endLat = endLat
        self.endLon = endLon
        self.speedLimitKmh = speedLimitKmh
        self.lengthMeters = lengthMeters
    }

    // MARK: - Computed

    var startCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: startLat, longitude: startLon)
    }

    var endCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: endLat, longitude: endLon)
    }

    var startLocation: CLLocation {
        CLLocation(latitude: startLat, longitude: startLon)
    }

    var endLocation: CLLocation {
        CLLocation(latitude: endLat, longitude: endLon)
    }

    /// Distance in meters from a given coordinate to the start point.
    func distanceToStart(from coordinate: CLLocationCoordinate2D) -> CLLocationDistance {
        let loc = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        return loc.distance(from: startLocation)
    }

    /// Distance in meters from a given coordinate to the end point.
    func distanceToEnd(from coordinate: CLLocationCoordinate2D) -> CLLocationDistance {
        let loc = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        return loc.distance(from: endLocation)
    }

    /// Returns true if the given coordinate is within `threshold` meters
    /// of the start point.
    func isNearStart(_ coordinate: CLLocationCoordinate2D, threshold: CLLocationDistance = 150) -> Bool {
        distanceToStart(from: coordinate) <= threshold
    }

    /// Returns true if the given coordinate is past the end point
    /// (within `threshold` meters), meaning the zone has been traversed.
    func isPastEnd(_ coordinate: CLLocationCoordinate2D, threshold: CLLocationDistance = 200) -> Bool {
        distanceToEnd(from: coordinate) <= threshold
    }
}

// MARK: - Tutor Zone Database

/// Lightweight container for all Tutor zones, loaded from a bundled JSON file.
struct TutorZoneDatabase: Codable {
    let version: String
    let lastUpdated: String
    let zones: [TutorZone]
}

// MARK: - Tutor Zone Session Summary

/// Summary produced after completing a Tutor zone traversal.
struct TutorZoneSummary {
    let zoneName: String
    let highway: String
    let averageSpeedKmh: Double
    let speedLimitKmh: Int
    let lengthKm: Double
    let durationSeconds: TimeInterval
    let wasCompliant: Bool
}
