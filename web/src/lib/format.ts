// Blastek content conventions: MAD currency, 24h time in the dashboard,
// 12h in customer-facing strings, "Tue, 12 May" dates.

export const pad2 = (n: number) => String(n).padStart(2, '0');

export const fmtMoney = (n: number) =>
  `${Number.isInteger(n)
    ? n.toLocaleString('en-US')
    : n.toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 })} MAD`;

export const fmtTime = (min: number, clock12 = false) => {
  const h = Math.floor(min / 60), m = min % 60;
  if (!clock12) return `${pad2(h)}:${pad2(m)}`;
  return `${((h + 11) % 12) + 1}:${pad2(m)} ${h < 12 ? 'AM' : 'PM'}`;
};

export const fmtDur = (min: number) =>
  min >= 60
    ? `${Math.floor(min / 60)}h${min % 60 ? ' ' + (min % 60) + 'min' : ''}`
    : `${min}min`;

export const todayStr = () => {
  const d = new Date();
  return `${d.getFullYear()}-${pad2(d.getMonth() + 1)}-${pad2(d.getDate())}`;
};

export const addDays = (ds: string, n: number) => {
  const d = new Date(ds + 'T12:00:00');
  d.setDate(d.getDate() + n);
  return `${d.getFullYear()}-${pad2(d.getMonth() + 1)}-${pad2(d.getDate())}`;
};

export const WEEKDAYS = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
export const WEEKDAYS_FULL = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'];
const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
const MONTHS_FULL = ['January', 'February', 'March', 'April', 'May', 'June', 'July',
  'August', 'September', 'October', 'November', 'December'];

export const fmtDateShort = (ds: string) => {
  const d = new Date(ds.slice(0, 10) + 'T12:00:00');
  return `${WEEKDAYS[d.getDay()]}, ${d.getDate()} ${MONTHS[d.getMonth()]}`;
};

export const fmtDateLong = (ds: string) => {
  const d = new Date(ds.slice(0, 10) + 'T12:00:00');
  return `${WEEKDAYS_FULL[d.getDay()]}, ${d.getDate()} ${MONTHS_FULL[d.getMonth()]}`;
};

export const mondayOf = (ds: string) => {
  const d = new Date(ds + 'T12:00:00');
  return addDays(ds, -((d.getDay() + 6) % 7));
};

export const STATUS_LABEL: Record<string, string> = {
  booked: 'Booked', confirmed: 'Confirmed', started: 'In progress',
  completed: 'Completed', cancelled: 'Cancelled', no_show: 'No-show',
};

export const initials = (name: string) =>
  name.split(/\s+/).map((w) => w[0]).slice(0, 2).join('').toUpperCase();
