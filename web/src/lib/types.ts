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
  price: number;
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
  totalSpent?: number;
  appointments?: Appointment[];
}

export interface Appointment {
  id: string;
  bookingRef: string;
  date: string;
  startMin: number;
  endMin: number;
  status: string;
  price: number;
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
  amount: number;
}

export interface Sale {
  id: string;
  subtotal: number;
  tip: number;
  total: number;
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
}

export interface VenueHour {
  weekday: number;
  open: number | null;
  close: number | null;
}

/** Identity of a venue, without its catalog — for lists and cross-links. */
export interface VenueSummary {
  id: string;
  slug: string;
  name: string;
  city: string;
  status: string;
  tagline?: string;
  address?: string;
  phone?: string;
}

export interface Venue {
  id: string;
  slug: string;
  city: string;
  status: string;
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
  revenue: number;
  tips: number;
  salesCount: number;
  appointments: { completed: number; noShows: number; cancelled: number; online: number; total: number };
  newClients: number;
  revenueByDay: { day: string; revenue: number }[];
  topServices: { name: string; count: number; revenue: number }[];
  topStaff: { name: string; color: string; count: number; revenue: number }[];
}
