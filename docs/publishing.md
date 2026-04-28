---
id: publishing
title: Publishing
---

# Publishing

This repository is configured to publish its Docusaurus site to GitHub Pages.

## Local development

Install dependencies:

```bash
npm install
```

Start the local docs site:

```bash
npm run start
```

Build production assets:

```bash
npm run build
```

Preview the built site locally:

```bash
npm run serve
```

## GitHub Pages

The site is configured for:

- URL: `https://themuuln.github.io`
- Base URL: `/codex-orbit/`
- Branch deployment target: `gh-pages`

The docs deployment workflow publishes on pushes to `main` and supports manual dispatch from GitHub Actions.

## Publishing checklist

1. Ensure GitHub Pages is enabled for the repository.
2. Set the Pages source to GitHub Actions.
3. Push changes to `main`, or run the docs workflow manually.
4. Wait for the Pages deployment job to finish.
