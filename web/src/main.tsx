import React from 'react';
import ReactDOM from 'react-dom/client';
import { BrowserRouter } from 'react-router-dom';
import App from './App';
// Imported for its side effects, and imported *first*: it sets `lang`/`dir` on
// the document before React paints, so an Arabic visitor never sees a frame of
// left-to-right layout before it flips.
import './lib/i18n';
import './styles.css';

ReactDOM.createRoot(document.getElementById('root')!).render(
  <React.StrictMode>
    <BrowserRouter>
      <App />
    </BrowserRouter>
  </React.StrictMode>,
);

// Registered in production only: in dev the service worker would serve stale
// modules and fight Vite's HMR.
if ('serviceWorker' in navigator && import.meta.env.PROD) {
  window.addEventListener('load', () => {
    navigator.serviceWorker.register('/sw.js').catch(() => {
      // An unavailable service worker costs offline support, nothing more.
    });
  });
}
