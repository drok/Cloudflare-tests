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

  * `UNBUST_CACHE_KEY`: Secret key for encrypting the persistence database
  * `CF_BUG_756652_WORKAROUND`: Required only on Cloudflare Pages, ([bug 756652](https://community.cloudflare.com/t/branch-alias-url-for-pages-production-env/756652)): two word setting. First word: Production Environemnt branch name, Second word: project URL (at pages.dev). Eg. for this project (`unbust`), the Production branch for the demo site is `unbust/demo`, so the correct setting is `unbust/demo https://unbust.pages.dev`.

Optional settings:

  * `UNBUST_CACHE_TIME`: How long to cache entry points in seconds (default: `86400`, ie, one day). If there is a policy script, this setting is a space-separated list of cache times, one for each policy state, starting with 100.
  * `UNBUST_CACHE_SUPPORT`: How long this deployment will be supported in days (default: `90`, ie, 3 months). If there is a policy script, this setting is a space-separated list of support times, one for each policy state, starting with 100.
  * `UNBUST_CACHE_DBNAME`: Name of the encrypted persistence database file (default: `my-unbust-db`)

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

When a policy script is used, the *_TIME and *_SUPPORT variables are lists of cache times and support times, one for each policy state, starting with 100. The first value corresponds to policy state 100, the second to 101, and so on.

"Support" means the developer commits to keep this deployment working correctly for this many days.
"Cache time" is used as the max-time parameter of the `Cache-Control` header.

Together the support and cache time determine when the versioned published files (eg, app.[hash].js) are kept in the 'deprecated' state. After a newer version of the site is deployed, old files are considered 'deprecated' until the end of support period, after which they are "obsolete" and no longer persisted in deployments. The two variables are used by the unbust.sh script to determine which old files to keep around, and should be used by the policy script as policy parameters to generate headers configuration for the CDN, and to communicate the support commitment to the browser.

Knowing when support ends for a website version allows the browser to reload at support expiration. Otherwise, it risks requesting assets which have been obsoleted and would result in 404 errors. This means the browser can precisely and reliably know when it can rely on static resources being available from the webserver. The demo site uses this info to automatically reload the page at the end of support, and it displays a progress bar indicating how much "freshness" remains before the forced reload.

Example:

   Suppose UNBUST_CACHE_TIME="600 86400 2592000" and UNBUST_CACHE_SUPPORT="30 90 365", and the three policy states are 100 (Hotfix-ready), 101 (Maintenance-ready), and 102 (Stable).

   This means that immediately after a new version is deployed, the site will be in "Hotfix-ready" state (for as long as your policy script decides). In this state, Cache-Control headers will be set to 10 minutes, and you're signalling to the browsers that you're committed to support this new version for 30 days. At the expiration of the 30 days, any visitors's browsers open tabs will reload.

   At the same time, if you fix any bugs during the hotfix-readiness window, new visitors will see the bugfixes within 10 minutes. Visitors with open tabs won't see the bugfixes unless the manually reload (F5) or they keep the tab open for 30 days, or navigate away and back after 10 minutes or longer (the browser will revalidate after 10 minutes)

    The Maintenance-readiness timing have similar semantics.

    On the other hand, once the project reaches Stable state, tabs can remain open for one year, and function reliably, even if in the meanwhile you release new versions. The open tabs will find the now deprecated assets for up to 365 days after the initial release. The long cache time of one month means that an SPA open in a tab will function even offline, as it will be cached on the device, and will not require revalidation for an entire month.

## CDN support

Some CDNs do not support custom "`Cache-Control`" headers. In that case, setting a cache policy is not possible.

| CDN | Persisted files | Cache policy | DEMO |
|:------------|:---|:---|:----|:---|
| Cloudflare Pages | Yes | Yes | [Demo](https://unbust.pages.dev/) |
| Netlify | Yes | Yes | [Demo](https://unbust.netlify.app/) |
| GitHub Pages | Yes | No | [Demo](https://Archivium.github.io/unbust/) |
| Vercel | Yes[^1] | No[^2] | [Demo](https://unbust.vercel.app/) |

[^1]: Custom install command required: `yum -y install wget`
[^2]: Headers can only be hardcoded via `vercel.json` from git. The platform does not read this cfg after the build runs, so the build (and the cache-policy script) cannot set the cache-control headers.

## Installation

The easiest way to install `unbust.sh` in your project is to merge the `[unbust/main](/Archivium/unbust)` branch into your project. Reject the `README.md` file (if it changes in the future, you'll get a merge conflict prompting you to remove the changes to the documentation).

1. Add `./unbust.sh <output-dir> <initial-commit-hash> [<cache-policy-script>]` to your CDN's build configuration, of if you use a javascript framework, you can add the equivalent to the build script in your `project.json` file.

2. (Optionally) implement a cache policy script (can be done later). A good sample is found in the demos, including Github workflows implementing cron-based BUILD_HOOK deployments.

3. Implement a build strategy which generates versioned (unique) filenames for static resource when they change. Webpack and similar tools do this easily (see webpack's [Output Filenames guide](https://webpack.js.org/guides/caching/#output-filenames)).

**NOTE** the `initial-commit-hash` argument is very important. It is used to avoid inadvertent persistence DB reset. If the argument matches the deployed commit, and a persistence DB is not found at the `PUBLIC_URL`, the script initializes a new DB (thus discarding any old persistence state). If the argument does not match the commit, the script errors out, refusing to gneerate a new DB. In case of configuration errors, outages or bugs, persistence will not be easily reset.

4. **IMPORTANT** Remove "cache-busting" techniques from your site. They are no longer needed, and are counter productive.

## Post install considerations

This script will put an end to 404's due to missing sub-resources, so you no longer need to resort to 'cache-busting' tricks to attempt avoiding errors in the browser.

With errors reliably eliminated, you are able to rely on caching to improve performance. Use the cache policy to make good use of browser and edge caching (they are your friends). Deciding how long the cache times should be no longer depends on fears of errors, but on deliberate roll-out planning. A long cache time will make future rollouts predictably placed (eg, a 1-month cache time means your user base will be transition to the new version over 1 month). This allows you to limit damage due to botched releases.

Normally minor revisions do not need to be rolled out immediately to all users. Rolling out major revisions is a matter of planning. Do you want all users to experience the new version ASAP, or is it acceptable to introduce gradually? A quick rollout is more risky, because everyone will see all the bugs. A slow rollout means not everyone will benefit from the new features right away, and you'll have to maintain both new and old backend technology for the (longer) rollout perion.

The choice of rollout strategy is beyond the scope of this `README`, suffice to say, the `unbust.sh` script gives you the control and predictability, while giving your users the benefit of full use of the available browser and CDN edge caching.

As the demos show, you can have a deliberate rollout including planned hotfix and maintenance windows.
