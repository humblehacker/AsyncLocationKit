//  MIT License
//
//  Copyright (c) 2022 AsyncSwift
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in all
//  copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
//  SOFTWARE.

import Foundation
import CoreLocation

public typealias AuthotizationContinuation = CheckedContinuation<CLAuthorizationStatus, Never>
public typealias AccuracyAuthorizationContinuation = CheckedContinuation<CLAccuracyAuthorization?, Error>
public typealias LocationOnceContinuation = CheckedContinuation<LocationUpdateEvent?, Error>
public typealias LocationEnabledStream = AsyncStream<LocationEnabledEvent>
public typealias LocationStream = AsyncStream<LocationUpdateEvent>
public typealias RegionMonitoringStream = AsyncStream<RegionMonitoringEvent>
public typealias VisitMonitoringStream = AsyncStream<VisitMonitoringEvent>
public typealias HeadingMonitorStream = AsyncStream<HeadingMonitorEvent>
public typealias AuthorizationStream = AsyncStream<AuthorizationEvent>
public typealias AccuracyAuthorizationStream = AsyncStream<AccuracyAuthorizationEvent>
public typealias BeaconsRangingStream = AsyncStream<BeaconRangeEvent>

public final class AsyncLocationManager {
    private var locationManager: CLLocationManager
    private var proxyDelegate: AsyncDelegateProxyInterface
    private var locationDelegate: CLLocationManagerDelegate
    private var desiredAccuracy: LocationAccuracy = .bestAccuracy

    public init() {
        locationManager = CLLocationManager()
        proxyDelegate = AsyncDelegateProxy()
        locationDelegate = LocationDelegate(delegateProxy: proxyDelegate)
        locationManager.delegate = locationDelegate
        locationManager.desiredAccuracy = desiredAccuracy.convertingAccuracy
    }

    public init(locationManager: CLLocationManager, desiredAccuracy: LocationAccuracy) {
        self.locationManager = locationManager
        proxyDelegate = AsyncDelegateProxy()
        locationDelegate = LocationDelegate(delegateProxy: proxyDelegate)
        self.locationManager.delegate = locationDelegate
        self.locationManager.desiredAccuracy = desiredAccuracy.convertingAccuracy
    }

    public convenience init(desiredAccuracy: LocationAccuracy) {
        self.init()
        self.desiredAccuracy = desiredAccuracy
    }

    public func getLocationEnabled() async -> Bool {
        // Though undocumented, `locationServicesEnabled()` must not be called from the main thread. Otherwise,
        // we get a runtime warning "This method can cause UI unresponsiveness if invoked on the main thread"
        // Therefore, we use `Task.detached` to ensure we're off the main thread.
        await Task.detached { CLLocationManager.locationServicesEnabled() }.value
    }

    public func getAuthorizationStatus() -> CLAuthorizationStatus {
        if #available(iOS 14, *) {
            return locationManager.authorizationStatus
        } else {
            return CLLocationManager.authorizationStatus()
        }
    }

    public func startMonitoringLocationEnabled() async -> LocationEnabledStream {
        let performer = LocationEnabledMonitoringPerformer()
        return LocationEnabledStream { stream in
            performer.linkContinuation(stream)
            proxyDelegate.addPerformer(performer)
            stream.onTermination = { @Sendable _ in
                self.stopMonitoringLocationEnabled()
            }
        }
    }

    public func stopMonitoringLocationEnabled() {
        proxyDelegate.cancel(for: LocationEnabledMonitoringPerformer.self)
    }

    public func startMonitoringAuthorization() async -> AuthorizationStream {
        let performer = AuthorizationMonitoringPerformer()
        return AuthorizationStream { stream in
            performer.linkContinuation(stream)
            proxyDelegate.addPerformer(performer)
            stream.onTermination = { @Sendable _ in
                self.stopMonitoringAuthorization()
            }
        }
    }

    public func stopMonitoringAuthorization() {
        proxyDelegate.cancel(for: AuthorizationMonitoringPerformer.self)
    }

    public func startMonitoringAccuracyAuthorization() async -> AccuracyAuthorizationStream {
        let performer = AccuracyAuthorizationMonitoringPerformer()
        return AccuracyAuthorizationStream { stream in
            performer.linkContinuation(stream)
            proxyDelegate.addPerformer(performer)
            stream.onTermination = { @Sendable _ in
                self.stopMonitoringAccuracyAuthorization()
            }
        }
    }

    public func stopMonitoringAccuracyAuthorization() {
        proxyDelegate.cancel(for: AccuracyAuthorizationMonitoringPerformer.self)
    }

    @available(iOS 14, *)
    public func getAccuracyAuthorization() -> CLAccuracyAuthorization {
        locationManager.accuracyAuthorization
    }

    public func updateAccuracy(with newAccuracy: LocationAccuracy) {
        locationManager.desiredAccuracy = newAccuracy.convertingAccuracy
    }

    @available(*, deprecated, message: "Use new function requestPermission(with:)")
    public func requestAuthorizationWhenInUse() async -> CLAuthorizationStatus {
        let authorizationPerformer = RequestAuthorizationPerformer(currentStatus: getAuthorizationStatus())
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                let authorizationStatus = getAuthorizationStatus()
                if authorizationStatus != .notDetermined {
                    continuation.resume(with: .success(authorizationStatus))
                } else {
                    authorizationPerformer.linkContinuation(continuation)
                    proxyDelegate.addPerformer(authorizationPerformer)
                    locationManager.requestWhenInUseAuthorization()
                }
            }
        }, onCancel: {
            proxyDelegate.cancel(for: authorizationPerformer.uniqueIdentifier)
        })
    }

#if !APPCLIP
    @available(*, deprecated, message: "Use new function requestPermission(with:)")
    public func requestAuthorizationAlways() async -> CLAuthorizationStatus {
        let authorizationPerformer = RequestAuthorizationPerformer(currentStatus: getAuthorizationStatus())
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                if #available(iOS 14, *), locationManager.authorizationStatus != .notDetermined && locationManager.authorizationStatus != .authorizedWhenInUse {
                    continuation.resume(with: .success(locationManager.authorizationStatus))
                } else {
                    authorizationPerformer.linkContinuation(continuation)
                    proxyDelegate.addPerformer(authorizationPerformer)
                    locationManager.requestAlwaysAuthorization()
                }
            }
        }, onCancel: {
            proxyDelegate.cancel(for: authorizationPerformer.uniqueIdentifier)
        })
    }
#endif

    public func requestPermission(with permissionType: LocationPermission) async -> CLAuthorizationStatus {
        switch permissionType {
        case .always:
            #if APPCLIP
            return await locationPermissionWhenInUse()
            #else
            return await locationPermissionAlways()
            #endif
        case .whenInUsage:
            return await locationPermissionWhenInUse()
        }
    }

    @available(iOS 14, *)
    public func requestTemporaryFullAccuracyAuthorization(purposeKey: String) async throws -> CLAccuracyAuthorization? {
        try await locationPermissionTemporaryFullAccuracy(purposeKey: purposeKey)
    }

    public func startUpdatingLocation() async -> LocationStream {
        let monitoringPerformer = MonitoringUpdateLocationPerformer()
        return LocationStream { streamContinuation in
            monitoringPerformer.linkContinuation(streamContinuation)
            proxyDelegate.addPerformer(monitoringPerformer)
            locationManager.startUpdatingLocation()
            streamContinuation.onTermination = { @Sendable _ in
                self.proxyDelegate.cancel(for: monitoringPerformer.uniqueIdentifier)
            }
        }
    }

    public func stopUpdatingLocation() {
        locationManager.stopUpdatingLocation()
        proxyDelegate.cancel(for: MonitoringUpdateLocationPerformer.self)
    }

    public func requestLocation() async throws -> LocationUpdateEvent? {
        let performer = SingleLocationUpdatePerformer()
        return try await withTaskCancellationHandler(operation: {
            return try await withCheckedThrowingContinuation({ continuation in
                performer.linkContinuation(continuation)
                self.proxyDelegate.addPerformer(performer)
                self.locationManager.requestLocation()
            })
        }, onCancel: {
            proxyDelegate.cancel(for: performer.uniqueIdentifier)
        })
    }

    public func startMonitoring(for region: CLRegion) async -> RegionMonitoringStream {
        let performer = RegionMonitoringPerformer(region: region)
        return RegionMonitoringStream { streamContinuation in
            performer.linkContinuation(streamContinuation)
            locationManager.startMonitoring(for: region)
            streamContinuation.onTermination = { @Sendable _ in
                self.proxyDelegate.cancel(for: performer.uniqueIdentifier)
            }
        }
    }

    public func stopMonitoring(for region: CLRegion) {
        proxyDelegate.cancel(for: RegionMonitoringPerformer.self) { regionMonitoring in
            guard let regionPerformer = regionMonitoring as? RegionMonitoringPerformer else { return false }
            return regionPerformer.region ==  region
        }
        locationManager.stopMonitoring(for: region)
    }

    public func startMonitoringVisit() async -> VisitMonitoringStream {
        let performer = VisitMonitoringPerformer()
        return VisitMonitoringStream { stream in
            performer.linkContinuation(stream)
            proxyDelegate.addPerformer(performer)
            locationManager.startMonitoringVisits()
            stream.onTermination = { @Sendable _ in
                self.stopMonitoringVisit()
            }
        }
    }

    public func stopMonitoringVisit() {
        proxyDelegate.cancel(for: VisitMonitoringPerformer.self)
        locationManager.stopMonitoringVisits()
    }

#if os(iOS)
    @available(iOS 13, *)
    public func startUpdatingHeading() async -> HeadingMonitorStream {
        let performer = HeadingMonitorPerformer()
        return HeadingMonitorStream { stream in
            performer.linkContinuation(stream)
            proxyDelegate.addPerformer(performer)
            locationManager.startUpdatingHeading()
            stream.onTermination = { @Sendable _ in
                self.stopUpdatingHeading()
            }
        }
    }

    public func stopUpdatingHeading() {
        proxyDelegate.cancel(for: HeadingMonitorPerformer.self)
        locationManager.stopUpdatingHeading()
    }
#endif

    public func startRangingBeacons(satisfying: CLBeaconIdentityConstraint) async -> BeaconsRangingStream {
        let performer = BeaconsRangePerformer(satisfying: satisfying)
        return BeaconsRangingStream { stream in
            performer.linkContinuation(stream)
            proxyDelegate.addPerformer(performer)
            locationManager.startRangingBeacons(satisfying: satisfying)
            stream.onTermination = { @Sendable _ in
                self.stopRangingBeacons(satisfying: satisfying)
            }
        }
    }

    public func stopRangingBeacons(satisfying: CLBeaconIdentityConstraint) {
        proxyDelegate.cancel(for: BeaconsRangePerformer.self) { beaconsMonitoring in
            guard let beaconsPerformer = beaconsMonitoring as? BeaconsRangePerformer else { return false }
            return beaconsPerformer.satisfying == satisfying
        }
        locationManager.stopRangingBeacons(satisfying: satisfying)
    }
}

extension AsyncLocationManager {
    private func locationPermissionWhenInUse() async -> CLAuthorizationStatus {
        let authorizationPerformer = RequestAuthorizationPerformer(currentStatus: getAuthorizationStatus())
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                let authorizationStatus = getAuthorizationStatus()
                if authorizationStatus != .notDetermined {
                    continuation.resume(with: .success(authorizationStatus))
                } else {
                    authorizationPerformer.linkContinuation(continuation)
                    proxyDelegate.addPerformer(authorizationPerformer)
                    locationManager.requestWhenInUseAuthorization()
                }
            }
        }, onCancel: {
            proxyDelegate.cancel(for: authorizationPerformer.uniqueIdentifier)
        })
    }

    private func locationPermissionAlways() async -> CLAuthorizationStatus {
        let authorizationPerformer = RequestAuthorizationPerformer(currentStatus: getAuthorizationStatus())
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                if #available(iOS 14, *), locationManager.authorizationStatus != .notDetermined && locationManager.authorizationStatus != .authorizedWhenInUse {
                    continuation.resume(with: .success(locationManager.authorizationStatus))
                } else {
                    authorizationPerformer.linkContinuation(continuation)
                    proxyDelegate.addPerformer(authorizationPerformer)
                    locationManager.requestAlwaysAuthorization()
                }
            }
        }, onCancel: {
            proxyDelegate.cancel(for: authorizationPerformer.uniqueIdentifier)
        })
    }

    @available(iOS 14, *)
    private func locationPermissionTemporaryFullAccuracy(purposeKey: String) async throws -> CLAccuracyAuthorization? {
        let authorizationPerformer = RequestAccuracyAuthorizationPerformer()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CLAccuracyAuthorization?, Error>) in
                if locationManager.authorizationStatus == .notDetermined {
                    continuation.resume(with: .success(nil))
                } else if locationManager.accuracyAuthorization == .fullAccuracy {
                    continuation.resume(with: .success(locationManager.accuracyAuthorization))
                } else if !CLLocationManager.locationServicesEnabled() {
                    continuation.resume(with: .success(nil))
                } else {
                    authorizationPerformer.linkContinuation(continuation)
                    proxyDelegate.addPerformer(authorizationPerformer)
                    locationManager.requestTemporaryFullAccuracyAuthorization(withPurposeKey: purposeKey) { error in
                        if let error {
                            continuation.resume(with: .failure(error))
                            return
                        }

                        // If the user chooses reduced accuracy, the didChangeAuthorization delegate method
                        // will not called. So we must emulate that here.
                        if self.locationManager.accuracyAuthorization == .reducedAccuracy {
                            self.proxyDelegate.eventForMethodInvoked(
                                .didChangeAccuracyAuthorization(authorization: self.locationManager.accuracyAuthorization)
                            )
                        }
                        print("got temporary full accuracy authorization \(self.locationManager.accuracyAuthorization.rawValue)")
                    }
                }
            }
        }, onCancel: {
            proxyDelegate.cancel(for: authorizationPerformer.uniqueIdentifier)
        })
    }
}

extension CLAuthorizationStatus: CustomStringConvertible {
    public var description: String {
        switch self {
        case .notDetermined: return ".notDetermined"
        case .restricted: return ".restricted"
        case .denied: return ".denied"
        case .authorizedWhenInUse: return ".authorizedWhenInUse"
        case .authorizedAlways: return ".authorisedAlways"
        @unknown default: return "unknown \(rawValue)"
        }
    }
}

extension CLAccuracyAuthorization: CustomStringConvertible {
    public var description: String {
        switch self {
        case .fullAccuracy: return ".fullAccuracy"
        case .reducedAccuracy: return ".reducedAccuracy"
        @unknown default: return "unknown \(rawValue)"
        }
    }
}

