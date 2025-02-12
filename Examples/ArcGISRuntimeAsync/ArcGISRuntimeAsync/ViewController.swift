// Copyright 2021 Esri.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//   http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import UIKit
import ArcGIS

import ArcGISAsyncAwait

class ViewController: UIViewController, UISearchBarDelegate {
    
    // MARK: General UI
    @IBOutlet weak var calculateRouteView: UIStackView!
    @IBOutlet weak var calculateRouteButton: UIButton!
    
    @IBOutlet weak var cancelCalculationView: UIStackView!
    @IBOutlet weak var cancelCalculationButton: UIButton!
    @IBOutlet weak var calculatingView: UIView!
    @IBOutlet weak var calculatingLabel: UILabel!
    
    @IBOutlet weak var logTextView: UITextView!
    
    @IBOutlet weak var activityIndicator: UIActivityIndicatorView!
    @IBOutlet weak var progressView: UIProgressView!
    
    // MARK: Map UI
    @IBOutlet weak var mapView: AGSMapView! {
        didSet {
            // To use a map, set the API Key. See AppDelegate.swift.
            let map = AGSMap(basemapStyle: .arcGISNavigation)
            
            // Display the map in the map view
            mapView.map = map
            
            // Add graphics overlays to the map view
            mapView.graphicsOverlays.add(routeResultOverlay)
            mapView.graphicsOverlays.add(geocodeOverlay)
            
            Task {
                do {
                    // Explicitly load the map's metadata to read its spatial reference
                    try await map.load()
                    logMessage("Map is loaded")
                    
                    if let sr = map.spatialReference {
                        logMessage("Map's spatial reference is \(sr)")
                    }
                } catch {
                    showError(title: "Error loading the map", error: error)
                }
            }
        }
    }
    
    // MARK: Map view overlays
    let routeResultOverlay = AGSGraphicsOverlay()
    let geocodeOverlay = AGSGraphicsOverlay()
    
    // MARK: Platform service tasks
    let locatorTask = AGSLocatorTask(url: URL(string: "https://geocode-api.arcgis.com/arcgis/rest/services/World/GeocodeServer")!)
    let routeTask = AGSRouteTask(url: URL(string: "https://route-api.arcgis.com/arcgis/rest/services/World/Route/NAServer/Route_World")!)
    
    // MARK: Cancellable async task reference
    /// A property used to cancel the route calculation.
    ///
    /// To cancel a long running ArcGIS Runtime operation, wrap it in a cancelable async/await Task. You then cancel the task,
    /// which in turn will cancel the ArcGIS Runtime operation.
    ///
    /// This is set in the `getRoute()` method, and used in the `cancelRoute()` @IBAction.
    @MainActor var cancelableRouteCalculation: Task<AGSRouteResult, Error>? = nil
    @MainActor var cancelableGenericCalculation: Task<Any, Error>? = nil
    
    // MARK: View setup
    override func viewDidLoad() {
        super.viewDidLoad()
        // Do any additional setup after loading the view.
        
        setupUI()
        
        Task {
            do {
                // Load metadata now to avoid any delay when doing our first geocode later.
                try await locatorTask.load()
                logMessage("Locator Task ready")
            } catch {
                showError(title: "Load Locator Task", error: error)
            }
        }
    }
    
}


// MARK: ArcGIS Runtime async/await calls
extension ViewController {
    
    /// Get a geocode result for given search text
    /// - Parameter searchText: The text to search for (e.g. "NYC" or "New York, NY", or "Eiffel Tower"
    /// - Returns: An AGSGeocodeResult that provides detailed information about the best result found for the search text.
    private func geocode(searchText: String) async throws -> AGSGeocodeResult? {
        // Get a geocode result
        let results = try await locatorTask.geocode(withSearchText: searchText)
        
        results.forEach {
            logMessage("Found \($0.label) with score \($0.score) at \(String(format: "%.4f,%4f", $0.displayLocation!.y, $0.displayLocation!.x))")
        }
        
        // Estimate the size of a tile package covering a 500m radius area around the geocode result's location.
        return results.first
    }
    
    /// This method will call a service to estimate the number of tiles and size of a tile package that could be generated from the World Imagery service to cover a given area of interest.
    /// - Parameter areaOfInterest: An area of interest (could be a polygon or an extent)
    /// - Returns: An AGSEstimateTileCacheSizeResult object that includes the number of tiles and the size (in bytes) that requesting a tile package would result in.
    private func estimateTiles(areaOfInterest: AGSGeometry) async throws -> AGSEstimateTileCacheSizeResult {
        // Create the task, get default parameters for it using the area of interest (async), and create a job.
        let exportTileCacheTask = AGSExportTileCacheTask(url: URL(string: "https://tiledbasemaps.arcgis.com/arcgis/rest/services/World_Imagery/MapServer")!)
        
        let parameters = try await exportTileCacheTask.exportTileCacheParameters(withAreaOfInterest: areaOfInterest, minScale: 100000, maxScale: 1)
        
        let job = exportTileCacheTask.estimateTileCacheSizeJob(with: parameters)
        
        await MainActor.run {
            progressView.observedProgress = job.progress
        }
        
        // Execute the job (async) printing feedback messages as they arrive.
        logMessage("Starting Estimate Export Tiles job.")
        
        cancelableGenericCalculation = Task { () -> AGSEstimateTileCacheSizeResult in
            var lastPrintedMessageIndex = 0
            let estimate = try await job.start(statusHandler: { [weak self] status in
                for message in job.messages[lastPrintedMessageIndex...] {
                    self?.logMessage("-> \(message.message)")
                }
                lastPrintedMessageIndex = job.messages.count
            })
            
            return estimate
        }
        
        return try await cancelableGenericCalculation!.value as! AGSEstimateTileCacheSizeResult
    }
    
    /// This method will calculate a route between two points.
    ///
    /// The calculation can be canceled.
    /// - Parameters:
    ///   - start: The start of route.
    ///   - finish: The end of route.
    /// - Returns: A route result.
    private func calculateRoute(from start: AGSStop, to finish: AGSStop) async throws -> AGSRouteResult {
        
        // Store the cancelable task so the Cancel button can cancel it.
        cancelableRouteCalculation = Task { () -> AGSRouteResult in
            let startTime = Date()
            
            // Get default route parameters (first time, this will load the AGSRouteTask)
            logMessage("Fetching default route parameters…")
            let routeParameters = try await routeTask.defaultRouteParameters()
            
            // Modify the parameters with the stops we're interested in.
            logMessage("Settings stops…")
            routeParameters.setStops([start, finish])
            
            // Calculate a route between the stop stops.
            logMessage("Calculating route…")
            let result = try await routeTask.solveRoute(with: routeParameters)
            logMessage("Calculated route.")
            
            let calculationTime = Date().timeIntervalSince(startTime)
            logMessage("Route calculation took about \(String(format: "%.1f", calculationTime)) seconds")
            
            return result
        }
        
        return try await cancelableRouteCalculation!.value
    }
    
}

// MARK: UI interaction (IBActions etc.)
extension ViewController {
    
    /// Geocode and estimate a tile cache, handling any cancel requests from the user.
    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        guard let searchText = searchBar.text,
              !searchText.isEmpty else { return }
        
        searchBar.resignFirstResponder()
        
        Task {
            await showCalculatingView(message: "Geocoding…")
            
            do {
                
                try await geocodeAndDisplayResult(searchText: searchText)
                
            } catch let error as CocoaError where error.code == CocoaError.userCancelled {
                // Handle a cancelation. This is propagated as a userCancelled error.
                showAlert(title: "Canceled", message: "The request was canceled by the user.")
            } catch {
                showError(title: "Error geocoding/estimating", error: error)
            }
            
            await hideCalculatingView()
        }
    }
    
    /// Calculate a route from the west coast of the US to the east coast, handling any cancel requests from the user.
    @IBAction func calculateRouteButtonTapped(_ sender: Any) {
        
        Task {

            await showCalculatingView(message: "Calculating route…")
            
            do {
                // Cancelations are propagated as CocoaError.userCancelled errors. See the catch statement below.
                try await calculateAndDisplayRoute()
                
            } catch let error as CocoaError where error.code == CocoaError.userCancelled {
                // Handle a cancelation. This is propagated as a userCancelled error.
                showAlert(title: "Route canceled", message: "The route request was canceled by the user.")
            } catch {
                // Handle other (non-cancelation) errors.
                showError(title: "Error calculating route", error: error)
            }
            
            await hideCalculatingView()
            
        }
        
    }
    
    /// Cancels any currently executing route calculation using the async/await cancelable task pattern integrated with ArcGIS Runtime
    @IBAction func cancelRouteButtonTapped(_ sender: Any) {
        logMessage("Canceling…")
        cancelableRouteCalculation?.cancel()
        cancelableGenericCalculation?.cancel()
        logMessage("Canceled.")
    }
    
}


// MARK: Operation control flow
extension ViewController {
    
    /// Geocode some search text, then calculate a 500m buffer around it and estimate how many Imager tiles would be needed to take that are offline.
    /// Update the map view with Graphics representing the result, and log progress.
    ///
    /// This method will initiate a sequence of async ArcGIS Runtime operations and demonstrates:
    /// * Geocoding using the Task pattern
    /// * Estimating a tile package for download using the Job pattern
    /// * Zooming the map view without waiting for the zoom to complete before continuing
    /// * Referencing and updating graphics around an async/await call
    /// * Benefitting from the sequential nature of async/await code to simplify UI updates around other operations
    ///
    /// - Parameter searchText: Some search text, as entered in the UISearchBar. For example: NYC
    func geocodeAndDisplayResult(searchText: String) async throws {
        
        logMessage("Searching for \"\(searchText)\"")

        geocodeOverlay.graphics.removeAllObjects()

        let geocodeResult = try await geocode(searchText: searchText)
        
        guard let location = geocodeResult?.displayLocation,
              let areaOfInterest = AGSGeometryEngine.geodeticBufferGeometry(
                location,
                distance: 500, distanceUnit: .meters(),
                maxDeviation: Double.nan, curveType: .geodesic)
        else { return }
        
        // Show the geocode location, and a 500m area around it.
        let locationGraphic = AGSGraphic(
            geometry: location,
            symbol: AGSSimpleMarkerSymbol(style: .circle, color: .blue, size: 10)
        )
        
        let areaGraphic = AGSGraphic(
            geometry: areaOfInterest,
            symbol: AGSSimpleFillSymbol(
                style: .diagonalCross,
                color: .orange.withAlphaComponent(0.5),
                outline: AGSSimpleLineSymbol(style: .solid, color: .orange.withAlphaComponent(0.3), width: 2))
        )
        
        geocodeOverlay.graphics.addObjects(from: [areaGraphic, locationGraphic])
        
        // Zoom the map view in its own Task because we don't want to wait for the zoom animations
        // to complete before we start estimating tile sizes.
        Task {
            await mapView.setViewpointGeometry(geocodeResult?.extent ?? areaOfInterest)
            // Focus in on the area we're estimating tiles for.
            await mapView.setViewpoint(
                AGSViewpoint(targetExtent: areaOfInterest.extent.toBuilder().expand(byFactor: 1.5).toGeometry()),
                duration: 3,
                curve: .easeInOutCubic
            )
        }
        
        // Estimate the size of the tile package needed to download tiles for the 500m buffer.
        // Note, we don't actually download them - we'll just see how large the package would be.
        await showCalculatingView(message: "Estimating tiles to download…", withProgress: true)

        let estimate = try await estimateTiles(areaOfInterest: areaOfInterest)
        
        logMessage("Estimate Export Tiles job completed.")

        // Update the graphic to indicate that we've got a result.
        if let areaFill = areaGraphic.symbol as? AGSSimpleFillSymbol,
           let areaOutline = areaFill.outline as? AGSSimpleLineSymbol {
            areaFill.style = .solid
            areaOutline.width = 5
            areaOutline.color = areaOutline.color.withAlphaComponent(1)
        }
        
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        logMessage("Imagery tile cache estimate: \(estimate.tileCount) tiles, \(formatter.string(fromByteCount: Int64(estimate.fileSize)))")
    }
    
    /// Calculate and display a route from west coast to east coast, and log messages.
    ///
    /// The method demonstrates:
    /// * Using async/await with ArcGIS Runtime the Task pattern
    /// * Handling a cancel event (propagated through Runtime as a Cocoa.userCanceled Error)
    /// * Benefitting from the sequential nature of async/await code to simplify UI updates around other operations
    func calculateAndDisplayRoute() async throws {
        
        let leviStadium: AGSStop = {
            let stop = AGSStop(point: AGSPointMakeWGS84(37.403190166819925, -121.96976999999998))
            stop.name = "Levi Stadium"
            return stop
        }()
        
        let gilletteStadium: AGSStop = {
            let stop = AGSStop(point: AGSPointMakeWGS84(42.090960788263, -71.26438999999993))
            stop.name = "Gillette Stadium"
            return stop
        }()

        // Remove any previously displayed route result.
        routeResultOverlay.graphics.removeAllObjects()
        
        // Calculate the route asynchronously. This can be canceled from the `cancelRoute()` @IBAction.
        guard let route = try await calculateRoute(from: leviStadium, to: gilletteStadium).routes.first,
              let routeGeometry = route.routeGeometry else {
                  showAlert(title: "No route", message: "No valid route could be calculated.")
                  return
              }
        
        // Display the route in the map view.
        routeResultOverlay.graphics.add(AGSGraphic(
            geometry: routeGeometry,
            symbol: AGSSimpleLineSymbol(style: .solid, color: .red, width: 2)
        ))
        
        // Zoom the map view to the route.
        Task {
            // Put this in its own subtask so we don't wait for it to complete before we continue.
            await mapView.setViewpoint(
                AGSViewpoint(targetExtent: routeGeometry.extent.toBuilder().expand(byFactor: 1.1).toGeometry()),
                duration: 2,
                curve: .easeInOutCubic
            )
        }
        
        let routeDistanceFormatter: LengthFormatter = {
            let f = LengthFormatter()
            f.unitStyle = .long
            f.isForPersonHeightUse = false
            f.numberFormatter.maximumFractionDigits = 2
            return f
        }()

        let routeDurationFormatter: DateComponentsFormatter = {
            let f = DateComponentsFormatter()
            f.includesApproximationPhrase = true
            f.unitsStyle = .full
            f.includesApproximationPhrase = true
            f.allowedUnits = [.day, .hour, .minute]
            return f
        }()

        // And log some details about the route.
        logMessage("Got a route: \(route.routeName)")
        logMessage("\(routeDistanceFormatter.string(fromMeters: route.totalLength)) (\(routeDurationFormatter.string(from: route.totalTime * 60)!.lowercased()))")
    }

}
