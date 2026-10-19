# CompleteScanner website

The product page for CompleteScanner: a single static `index.html` (CSS and JavaScript inline) plus the screenshots in `assets/`.
To preview it, open `index.html` in a browser, or serve the folder with any static server, for example `python -m http.server 8000` from this folder and then visit http://localhost:8000.
There is no build step, so GitHub Pages can host the folder as it is (branch publishing only offers the repository root or `docs/`, so publish `site/` through a Pages deployment or copy it there).
