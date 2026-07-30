import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

// Dev server proxies to the Phoenix container so there's no CORS in dev.
export default defineConfig({
  plugins: [react()],
  server: {
    port: 5173,
    proxy: {
      '/api': 'http://localhost:4000',
      // GraphQL subscriptions (E2-T4, used by E6-T10). `ws: true` is the whole
      // point: without it the upgrade request is proxied as ordinary HTTP, the
      // socket never opens, and the dashboard simply never hears about a
      // booking — silently, because a subscription that fails to connect looks
      // exactly like one with nothing to report.
      '/socket': {
        target: 'ws://localhost:4000',
        ws: true,
      },
    },
  },
});
