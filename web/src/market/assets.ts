// Real photography (Unsplash-licensed, downloaded into /public/img so the app
// stays self-contained) + marketplace constants.
export const IMG = {
  hair1: '/img/hair-1.jpg',     // monochrome salon interior
  hair2: '/img/hair-2.jpg',     // stylist blow-drying
  hair3: '/img/hair-3.jpg',     // wash basin
  barber1: '/img/barber-1.jpg', // moody barbershop, warm lights
  barber2: '/img/barber-2.jpg', // beard trim, low light
  barber3: '/img/barber-3.jpg', // barber tools
  nails1: '/img/nails-1.jpg',   // dark manicure, gold rings
  nails2: '/img/nails-2.jpg',   // gel manicure
  spa1: '/img/spa-1.jpg',       // massage oil
  spa2: '/img/spa-2.jpg',       // towels & candle
  spa3: '/img/spa-3.jpg',       // facial treatment
  salon1: '/img/salon-1.jpg',   // burgundy salon chairs — Le Salon Anfa
};

export const CITIES = ['Casablanca', 'Rabat', 'Marrakech', 'Fès', 'Tanger', 'Agadir'];

const CATEGORY_IMG: Record<string, string> = {
  Hair: IMG.hair2,
  Barbering: IMG.barber1,
  Nails: IMG.nails1,
  'Massage & Spa' /* i18n-exempt: stock-photo credit metadata */: IMG.spa1,
};
export const categoryImg = (name: string) => CATEGORY_IMG[name] ?? IMG.salon1;
