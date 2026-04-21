# VoiceBabel Marketing Website

Static marketing site for VoiceBabel (the renamed WhisperUtil). Plain HTML + CSS + vanilla JS, no build step.

## Local preview

The page uses `fetch()` to load JSON language packs, so `file://` will not work. Serve over HTTP:

```bash
cd Website
python3 -m http.server 8000
# open http://localhost:8000
```

Language can be overridden via URL: `http://localhost:8000/?lang=zh-CN`.

## Deploy to Cloudflare Pages

1. Connect the repository to a new Cloudflare Pages project.
2. Build command: *(leave empty)*
3. Build output directory: `Website`
4. Framework preset: *None*

No environment variables, no build step, no dependencies.

## Add a new language

1. Copy `i18n/en.json` to `i18n/<code>.json` (e.g. `i18n/ja.json`). Use web-standard BCP-47 codes — `zh-CN`, `zh-TW`, `ja`, `ko`, `es`, etc.
2. Translate the values; leave keys untouched.
3. Open `scripts/main.js`, find the `SUPPORTED` array near the top, add one entry:
   ```js
   { code: "ja", label: "日本語" }
   ```
4. Ship. No HTML or CSS changes needed. Missing keys automatically fall back to English (per-key, not per-file).

## File layout

```
Website/
├── index.html            single-page structure, all copy via data-i18n keys
├── styles/main.css       design tokens + all styles
├── scripts/main.js       i18n loader + fade-in observer + language picker
├── i18n/
│   ├── en.json           authoritative English copy
│   └── zh-CN.json        Simplified Chinese copy
├── assets/               drop icon / screenshots / og-image here
├── README.md             this file
└── .gitignore
```

## TODO placeholders (fill in before launch)

Real marketing copy is not yet written. Search the JSON packs for `{{ TODO:` to find every slot:

- `i18n/en.json` and `i18n/zh-CN.json`:
  - `meta.description`
  - `hero.title`, `hero.subtitle`, `hero.icon_placeholder`
  - `features.transcribe.body`, `features.translate.body`, `features.privacy.body`
  - `howItWorks.step1.body`, `howItWorks.step2.body`, `howItWorks.step3.body`
  - `demo.placeholder`
  - `faq.q1`–`q5` and `faq.a1`–`a5`
  - `donate.body`
  - `download.coming_soon`
  - `footer.email`

Placeholders are visually highlighted on the rendered page (yellow dashed border) so unfilled copy is impossible to miss during review.

## Open decisions

- **Download channel**: GitHub Releases vs R2 vs Mac App Store. Update the `#download` section and `data-download-url` on `<body>` when chosen.
- **Donate platform**: Buy Me a Coffee / Ko-fi / GitHub Sponsors / none. Update the `#donate` CTA `href` and `data-platform` attribute.
- **Contact email**: pick a public-facing address (not the personal gmail).
- **Testimonials**: section is in markup with `hidden` — remove the attribute once quotes land.

## Assets to drop into `assets/`

- `icon.png` — 512×512 app icon (extract from the built `.app`).
- `og-image.png` — 1200×630 social share card.
- `screenshot-*.png` — app screenshots for the `#demo` section.
- `favicon.ico` — generate from the icon.
