# OpenRec landing page

The [openrec](https://github.com/ky-zo/openrec) marketing site. Next.js 16 with
Tailwind CSS v4 and Biome.

## Development

```bash
npm install
npm run dev
```

Then open [http://localhost:3000](http://localhost:3000).

## Scripts

| Command | What it does |
| --- | --- |
| `npm run dev` | Start the dev server |
| `npm run build` | Production build |
| `npm run start` | Serve the production build |
| `npm run lint` | Check with Biome |
| `npm run format` | Format with Biome |

## Structure

- `src/app/page.tsx` — the entire landing page
- `src/app/globals.css` — all page styles, including the app mockup
- `src/components/ui/` — shadcn-style primitives

The app mockup in the hero is hand-built CSS/HTML that mirrors the real macOS
UI, so it stays sharp at any resolution and in any theme. If the app's UI
changes, update the mockup markup in `page.tsx` to match.
