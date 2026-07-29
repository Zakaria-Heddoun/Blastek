// GraphQL result types. IDs arrive as strings from the API.

export interface Settings {
  businessName: string;
  businessTagline: string;
  businessAddress: string;
  businessPhone: string;
}

export interface Category {
  id: string;
  name: string;
  sort: number;
}

export interface Service {
  id: string;
  categoryId: string;
  name: string;
  description: string;
  durationMin: number;
  priceCents: number;
  active: boolean;
  staffIds: string[];
}

export interface StaffHour {
  weekday: number;
  working: boolean;
  startMin: number;
  endMin: number;
}

export interface Staff {
  id: string;
  name: string;
  role: string;
  color: string;
  active: boolean;
  hours: StaffHour[];
  serviceIds: string[];
}

export interface Client {
  id: string;
  firstName: string;
  lastName: string;
  email: string;
  phone: string;
  allergies: string;
  notes: string;
  createdAt?: string;
  apptCount?: number;
  totalSpentCents?: number;
  appointments?: Appointment[];
}

export interface Appointment {
  id: string;
  bookingRef: string;
  date: string;
  startMin: number;
  endMin: number;
  status: string;
  priceCents: number;
  notes: string;
  source: string;
  client: Client;
  service: Service;
  staff: Staff;
  // Present on customer-facing queries, which span venues.
  venue?: VenueSummary;
}

export interface SaleItem {
  id: string;
  description: string;
  amountCents: number;
}

export interface Sale {
  id: string;
  subtotalCents: number;
  tipCents: number;
  totalCents: number;
  paymentMethod: string;
  createdAt: string;
  client: Client;
  items: SaleItem[];
}

export interface Review {
  id: string;
  clientName: string;
  rating: number;
  comment: string;
  createdAt?: string;
}

export interface VenueHour {
  weekday: number;
  open: number | null;
  close: number | null;
}

/** Identity of a venue, without its catalog — for lists and cross-links. */
/** URLs of one photo's rendered sizes. Only `original` is always present. */
export interface PhotoUrls {
  original?: string;
  thumb?: string;
  card?: string;
  hero?: string;
}

export interface Photo {
  id: string;
  alt?: string;
  kind?: 'cover' | 'gallery';
  sort?: number;
  /** `pending` until the variant worker has run; `failed` if it was rejected. */
  status?: 'pending' | 'ready' | 'failed';
  width?: number | null;
  height?: number | null;
  urls?: PhotoUrls;
}

/** A presigned upload: PUT the file to `url`, replaying every header. */
export interface UploadTicket {
  photo: Photo;
  url: string;
  headers: { name: string; value: string }[];
}

export interface CityFacet {
  city: string;
  venueCount: number;
}

export interface CategoryFacet {
  name: string;
  serviceCount: number;
}

/** One page of search results; `totalCount` is the whole filtered set. */
export interface VenuePage {
  items: VenueSummary[];
  totalCount: number;
}

export interface VenueSummary {
  id: string;
  slug: string;
  name: string;
  city: string;
  status: string;
  tagline?: string;
  address?: string;
  phone?: string;
  /** Listing-card stats; only present when the query asks for them. */
  rating?: number;
  reviewCount?: number;
  priceFromCents?: number | null;
  lat?: number | null;
  lng?: number | null;
  /** Only on a search that supplied `near` — a property of the query. */
  distanceKm?: number | null;
  coverUrl?: string | null;
  photos?: Photo[];
  womenOnly?: boolean;
}

export interface Venue {
  id: string;
  slug: string;
  city: string;
  status: string;
  /** Null until the venue has been geocoded; the page falls back to an address card. */
  lat?: number | null;
  lng?: number | null;
  amenities?: string[];
  womenOnly?: boolean;
  photos?: Photo[];
  settings: Settings;
  categories: Category[];
  services: Service[];
  staff: Staff[];
  reviews: Review[];
  rating: number;
  hours: VenueHour[];
  stats: { bookings: number; professionals: number; services: number };
}

/** A venue the signed-in user administers, with their role in it. */
export interface VenueMembership {
  id: string;
  role: 'owner' | 'manager' | 'receptionist' | 'staff';
  venue: VenueSummary;
}

export interface Slot {
  startMin: number;
  staffId: string;
}

export interface BookingResult {
  bookingRef: string;
  date: string;
  startMin: number;
  endMin: number;
  staffName: string;
  appointments: Appointment[];
}

export interface ReportSummary {
  days: number;
  revenueCents: number;
  tipsCents: number;
  salesCount: number;
  appointments: { completed: number; noShows: number; cancelled: number; online: number; total: number };
  newClients: number;
  revenueByDay: { day: string; revenueCents: number }[];
  topServices: { name: string; count: number; revenueCents: number }[];
  topStaff: { name: string; color: string; count: number; revenueCents: number }[];
}
