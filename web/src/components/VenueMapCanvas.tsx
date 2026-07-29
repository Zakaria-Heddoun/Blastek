// Leaflet map, shared by the search results, the venue page and the dashboard's
// location picker (E8-T6, E8-T7).
//
// Markers are `divIcon`s rather than Leaflet's default image pins: the stock
// icons are referenced by relative URL and break under a bundler, and drawing
// them in CSS means they can be branded and given a real focus ring.
import { useEffect, useMemo } from 'react';
import { MapContainer, TileLayer, Marker, Tooltip, useMap, useMapEvents } from 'react-leaflet';
import L from 'leaflet';
import 'leaflet/dist/leaflet.css';
import './map.css';

export interface MapMarker {
  id: string;
  lat: number;
  lng: number;
  label?: string;
  /** Renders the marker as highlighted — used for the hovered result card. */
  active?: boolean;
  onClick?: () => void;
}

// Centred on Casablanca: the launch city, and a sane view when nothing is pinned.
const FALLBACK_CENTER: [number, number] = [33.5731, -7.5898];

function pinIcon(active: boolean) {
  return L.divIcon({
    className: `mapdot-wrap${active ? ' is-active' : ''}`,
    html: '<span class="mapdot"></span>',
    iconSize: [18, 18],
    iconAnchor: [9, 9],
  });
}

/** Keeps the viewport around whatever is currently on the map. */
function FitBounds({ markers, enabled }: { markers: MapMarker[]; enabled: boolean }) {
  const map = useMap();

  useEffect(() => {
    if (!enabled || markers.length === 0) return;

    if (markers.length === 1) {
      map.setView([markers[0].lat, markers[0].lng], 15);
      return;
    }

    map.fitBounds(
      L.latLngBounds(markers.map((m) => [m.lat, m.lng] as [number, number])),
      // Padding stops the outermost pins from sitting under the map edge.
      { padding: [36, 36], maxZoom: 15 },
    );
  }, [map, markers, enabled]);

  return null;
}

/** Click-to-place, for the dashboard's "drag the pin to your door" flow. */
function ClickToPick({ onPick }: { onPick: (lat: number, lng: number) => void }) {
  useMapEvents({
    click: (event) => onPick(event.latlng.lat, event.latlng.lng),
  });
  return null;
}

export default function VenueMap({
  markers,
  center,
  zoom = 13,
  onPick,
  height = 320,
  fitToMarkers = true,
  ariaLabel = 'Map',
}: {
  markers: MapMarker[];
  center?: [number, number];
  zoom?: number;
  onPick?: (lat: number, lng: number) => void;
  height?: number | string;
  fitToMarkers?: boolean;
  ariaLabel?: string;
}) {
  const initialCenter = useMemo<[number, number]>(() => {
    if (center) return center;
    if (markers.length > 0) return [markers[0].lat, markers[0].lng];
    return FALLBACK_CENTER;
  }, [center, markers]);

  return (
    <div className="venue-map" style={{ height }} role="region" aria-label={ariaLabel}>
      <MapContainer
        center={initialCenter}
        zoom={zoom}
        scrollWheelZoom={false}
        className="venue-map-canvas"
      >
        <TileLayer
          url="https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png"
          // Required by the OSM tile usage policy.
          attribution='&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a>'
          maxZoom={19}
        />

        <FitBounds markers={markers} enabled={fitToMarkers && !onPick} />
        {onPick && <ClickToPick onPick={onPick} />}

        {markers.map((marker) => (
          <Marker
            key={marker.id}
            position={[marker.lat, marker.lng]}
            icon={pinIcon(Boolean(marker.active))}
            eventHandlers={marker.onClick ? { click: marker.onClick } : undefined}
          >
            {marker.label && (
              <Tooltip direction="top" offset={[0, -10]}>
                {marker.label}
              </Tooltip>
            )}
          </Marker>
        ))}
      </MapContainer>

      {onPick && (
        <p className="venue-map-hint">Click the map to move the pin to your entrance.</p>
      )}
    </div>
  );
}
