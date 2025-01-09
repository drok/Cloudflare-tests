[![Netlify Status](https://api.netlify.com/api/v1/badges/d360c50c-a150-4328-9cb2-7ed857427267/deploy-status)](https://app.netlify.com/sites/drok-unbust/deploys)
![GitHub Pages Deploy](https://github.com/github/docs/actions/workflows/deploy-gh-pages.yml/badge.svg)
![Vercel](https://vercelbadge.vercel.app/api/drok/unbust)

# Unbust Cache Tool

This is a script that runs as part of a CI/CD pipeline for generating static website, and it preserves generated, versioned assets from one build to the next, avoiding 404 errors when opened tabs request old assets. It also implements a cache policy. Recently deployed sites are set to short cache time to allow quick hot-fixing, stable sites are set to longer cache times to increase performance and manage roll-out rate. See [DEMO](https://unbust.pages.dev) deployed at Cloudflare Pages. Netfly, GitHub Pages and Vercel are also supported.

## The Problem with Cache Busting

Cache busting is a common technique where filenames include a hash or version number (e.g., `app.a7ec317.js` or `app.min.js?v=3.33`) to force browsers to download new versions of files. While this ensures users get updated assets, it creates two significant problems:

### Problem 1 - Open tabs are broken

When you deploy a new version of your site, users who still have the old HTML/JS in their browsers will request the old versioned files - but those files no longer exist on the server, resulting in 404 errors and broken experiences.

This is especially problematic for:
- Long-running single page applications (SPAs)
- Users who keep tabs open for extended periods
- Mobile apps that may cache content for offline use

The `app.min.js?v=3.33` is especially problematic because the origin will serve the exact same file, regardless of the query string. Simultaneous requests for ?v=2.0 and ?v=3.33 will result in the same file being served, which is wrong for some of the running instances.

### Problem 2 - All browsers receve uncached data

If the `app.min.js?v=3.33` works as intended, proxies will ignore their caches due to the query string, and forward the request to origin. Not only will the browsers have to re-download data they already have, but they do it from the furthest source available, incuring the longest round-trip delay.

Some CDN's might refuse to fall for these shenanigans, and serve the file from the edge. The cost in terms of time, is a shorter round-trip delay than fetching from the origin, but nonetheless, it's a completely avoidable delay.

## The Solution: Asset Persistence

The `unbust.sh` script solves this by maintaining older versions of assets for a configurable time period (default 3 months). It:

1. Tracks which files were previously deployed
2. Automatically downloads and preserves old versions when deploying new ones
3. Ensures old asset versions remain available for browsers that need them
4. Automatically cleans up assets older than the retention period

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

## Usage

```bash
./unbust.sh <output-dir> <initial-commit-hash> [<cache-policy-script>]
```

Required environment variables:

  * UNBUST_CACHE_KEY: Secret key for encrypting the persistence database
  * PUBLIC_URL: The URL where your site is published (only required at Cloudflare, it is ignored and retrieved from the system build environment variables at build time)

Optional settings:

  * UNBUST_CACHE_TIME: How long to keep old files (default: `3 months ago`)
  * UNBUST_CACHE_DBNAME: Name of the encrypted persistence database file (default: `my-unbust-db`)

Implementing a cache policy is optional, by providing the `cache-policy-script` argument, which can be any script or excutable, which is run with state arguments. See below for CDN supporting custom "`Cache-Control`" headers. This implemented with BUILD_HOOKS running on a cron schedule to trigger re-deployment. The cache-policy script calculates the cache terms, or rejects the deployment if no change is needed.

Example deployment:
```bash
npm run build && ./tools/unbust.sh dist a7ec317 ./cache-policy.sh
```

## Cache Policy Script

The cache policy script is called with the following arguments:

   `./cache-pollicy.sh <deployment-state> <cache-policy-script> <output-dir>`

  1. "0" if the currently deployed source commit is the different than the previous deployment, or "1" if it is a repeat deployment
  1. The time in seconds since the previous successful deployment.
  1. The previous cache policy applied, or "initial" if it's the first
     deployment with a cache policy script present. This will be the
     same numeric code previously returned by the cache policy script
     (ie, 0 or 100-119)
  1. output directory

## CDN support

Some CDNs do not support custom "`Cache-Control`" headers. In that case, setting a cache policy is not possible.

| CDN | Persisted files | Cache policy | Auto `PUBLIC_URL` variable | DEMO |
|:------------|:---|:---|:----|:---|
| Cloudflare Pages | Yes | Yes | No | [Demo](https://unbust.pages.dev/) |
| Netlify | Yes | Yes | Yes | [Demo](https://unbust.netlify.app/) |
| GitHub Pages | Yes | No | Yes | [Demo](https://Archivium.github.io/unbust/) |
| Vercel | Yes[*] | No | Yes | [Demo](https://unbust.vercel.app/) |

[*] Custom install command required: `yum -y install wget`

## Installation

The easiest way to install `unbust.sh` in your project is to merge the [unbust/main](/Archivium/unbust) branch into your project. Reject the `README.md` file (if it changes in the future, you'll get a merge conflict prompting you to remove the changes to the documentation).

Add `./unbust.sh <output-dir> <initial-commit-hash> [<cache-policy-script>]` to your CDN's build configuration.

Optionally implement a cache policy script (can be done later). A good sample is found in the demos, including Github workflows implementing cron-based BUILD_HOOK deployments.

**NOTE** the `initial-commit-hash` argument is very important. It is used to avoid inadvertent persistence DB reset. If the argument matches the deployed commit, and a persistence DB is not found at the PUBLIC_URL, the script generates a new DB. If the argument does not match the commit, it errors out, refusing to gneerate a new DB. In case of configuration errors, persistence will not be easily reset in case of outages, or wrong argument or even bugs.

