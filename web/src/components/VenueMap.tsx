// Lazy boundary in front of the Leaflet map (E8-T6).
//
// Leaflet plus react-leaflet is ~150 kB of JavaScript, and most visits never
// open a map: the results page defaults to the list view, and a venue with no
// pin renders an address card instead. Loading it eagerly would put that weight
// on every first paint — which for a mobile-first app on Moroccan 4G is the
// difference between a fast homepage and a slow one.
//
// Consumers import this module and nothing changes at their call sites; the
// implementation lives in `VenueMapCanvas`, which is fetched on first use.
import { lazy, Suspense } from 'react';
import type { ComponentProps } from 'react';
import type VenueMapCanvas from './VenueMapCanvas';
import './map.css';

const Canvas = lazy(() => import('./VenueMapCanvas'));

export type { MapMarker } from './VenueMapCanvas';

type Props = ComponentProps<typeof VenueMapCanvas>;

export default function VenueMap(props: Props) {
  return (
    <Suspense
      fallback={
        // Reserves the map's exact height so the surrounding layout does not
        // shift when the chunk arrives.
        <div
          className="venue-map venue-map-loading"
          style={{ height: props.height ?? 320 }}
          aria-hidden="true"
        />
      }
    >
      <Canvas {...props} />
    </Suspense>
  );
}
