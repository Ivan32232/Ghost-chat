/**
 * Ghost Chat — Service Worker
 *
 * Стратегия кэширования:
 * - HTML: network-first (всегда свежий код, fallback на кэш при оффлайн)
 * - JS/CSS/Icons: cache-first с обновлением (быстрая загрузка)
 * - API/WS: без кэша (realtime данные)
 *
 * CACHE_VERSION меняется при каждом деплое — это форсирует обновление.
 */

const CACHE_VERSION = 'ghost-v11';

const STATIC_ASSETS = [
  '/',
  '/css/style.css?v=9',
  '/js/app.js?v=9',
  '/js/crypto.js',
  '/js/webrtc.js',
  '/js/voice.js',
  '/js/logger.js',
  '/js/security-monitor.js',
  '/icons/icon-192.png',
  '/icons/icon-512.png',
  '/manifest.json'
];

// Install: кэшируем все статические файлы
self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(CACHE_VERSION)
      .then(cache => cache.addAll(STATIC_ASSETS))
      .then(() => self.skipWaiting())
  );
});

// Activate: удаляем старые кэши
self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys()
      .then(keys => Promise.all(
        keys
          .filter(key => key !== CACHE_VERSION)
          .map(key => caches.delete(key))
      ))
      .then(() => self.clients.claim())
  );
});

// Fetch: стратегия зависит от типа запроса
self.addEventListener('fetch', (event) => {
  const url = new URL(event.request.url);

  // API и WebSocket — всегда сеть, без кэша
  if (url.pathname.startsWith('/api/') || url.pathname.startsWith('/ws') || event.request.url.startsWith('ws')) {
    return;
  }

  // HTML (chat root) — network-first (всегда свежий код)
  if (event.request.mode === 'navigate' || url.pathname === '/' || url.pathname === '') {
    event.respondWith(
      fetch(event.request)
        .then(response => {
          const clone = response.clone();
          caches.open(CACHE_VERSION).then(cache => cache.put(event.request, clone));
          return response;
        })
        .catch(() => caches.match(event.request))
    );
    return;
  }

  // JS, CSS, Icons — stale-while-revalidate
  event.respondWith(
    caches.match(event.request).then(cached => {
      const fetchPromise = fetch(event.request).then(response => {
        if (response.ok) {
          const clone = response.clone();
          caches.open(CACHE_VERSION).then(cache => cache.put(event.request, clone));
        }
        return response;
      }).catch(() => cached);

      return cached || fetchPromise;
    })
  );
});
