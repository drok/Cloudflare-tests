# Unbust Cache Tool

## The Problem with Cache Busting

Cache busting is a common technique where filenames include a hash or version number (e.g., `app.a7ec317.js` or app.min.js?v=3.33) to force browsers to download new versions of files. While this ensures users get updated assets, it creates a significant problem:

When you deploy a new version of your site, users who still have the old HTML/JS in their browsers will request the old versioned files - but those files no longer exist on the server, resulting in 404 errors and broken experiences.

This is especially problematic for:
- Long-running single page applications (SPAs)
- Users who keep tabs open for extended periods
- Mobile apps that may cache content for offline use

The `app.min.js?v=3.33` is especially problematic because the origin will serve the exact same file, regardless of the query string. Simultaneous requests for ?v=2.0 and ?v=3.33 will result in the same file being served, which is wrong for some of the running instances.

## The Solution: Asset Persistence

The `unbust.sh` script solves this by maintaining older versions of assets for a configurable time period (default 3 months). It:

1. Tracks which files were previously deployed
2. Automatically downloads and preserves old versions when deploying new ones
3. Ensures old asset versions remain available for browsers that need them
4. Automatically cleans up assets older than the retention period

## Usage

```bash
./unbust.sh <output-dir> <initial-commit-hash>
```

Required environment variables:

PUBLIC_URL: The URL where your site is published
UNBUST_CACHE_KEY: Secret key for encrypting the persistence database

Optional settings:

UNBUST_CACHE_TIME: How long to keep old files (default: "3 months ago")
UNBUST_CACHE_DBNAME: Name of the encrypted persistence database file

Example deployment:
```bash
npm run build && ./tools/unbust.sh dist a7ec317
```

## Benefits

* No more 404 errors for active user sessions
* Smooth transitions between deployments
* Automatic cleanup of truly obsolete assets
* Simple integration into existing build processes
* Works with Cloudflare Pages out of the box

## How It Works

The script maintains an encrypted git repository containing records of all deployed files. This is the "persistence database". When deploying:

  1. It downloads the existing, encrypted persistence database
  1. Records the new files being deployed
  1. Downloads any missing old versions that are still within the retention period
  1. Updates and re-encrypts the persistence database

