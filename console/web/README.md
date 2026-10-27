# Web console

React/Vite frontend for the cc-util operator console. See
[`../README.md`](../README.md) for setup, demo, and architecture notes.

```sh
npm run dev -w web   # Vite only, proxies API to :3000
npm run build -w web # typecheck + production build
npm run lint -w web  # Oxlint
```

The app imports shared payload types from `@shared/api` and UI code from `@/`.
