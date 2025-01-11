#!/bin/bash

# ############## DEMO CACHE POLICY ######################
#
# This policy corresponds to suggestions given in the unbust.sh header
# with two exceptions:
# For DEMO purposes, the "Demo logic" segment below forces a hotfix/redeployment
# cycle every month on the 3rd of the month.
#
# The *_desc and *_till and cache_policy are used only to fill placeholders
# in index.html (the demo page). You won't want these if you copy this file
# as a template. Or, you may do something else, like email your team or
# setting calendar reminders of when the hotfix and maintenance windows close.
# ########################################################
set -x
set -o errexit

[[ $# -eq 4 ]] || {
    echo "Usage: $0 <is_redeployement> <time_since_last_deployment> <last_cache_state> <output_dir>";
    exit 1;
}

is_redeployement=$1
time_since_last_deployment=$2
last_cache_state=$3
output_dir=$4

[[ ${UNBUST_CACHE_SUPPORT:+isset} ]] || {
	UNBUST_CACHE_SUPPORT=90 # 3 months.
}

[[ ${UNBUST_CACHE_TIME:+isset} ]] || {
	UNBUST_CACHE_TIME=$(( 24 * 3600 )) # one day, in seconds
}

# ############# Policy choices ############################
hotfix_period=$((3600 * 24 * 7))
hotfix_period_desc="1 week"

maintenance_period=$((3600 * 24 * 7 * 3))
maintenance_period_desc="3 weeks"

# ############# Demo logic ############################
# For the Demo, pretend that builds at 2 AM on the 3rd of the month are new builds.
# Github's cron job triggers every day at 2 AM UTC
# If you use this demo policy as template, you'd want to "exit 1" unconditionally here.
# #####################################################
NOW=$(date --iso=seconds)
mohour=$(date -d "$NOW" -u +%d%H%M)
if [[ ${mohour::5} == "03020" ]] ; then
    is_redeployement=0
fi

# ############# Cache policy logic ############################

# Bomb out if any vars are forgotten, declining the deployment
set -o nounset

if [[ $is_redeployement == 0 ]] ; then
    cache_state=100 # Hotfix-ready
else
    unset cache_state
    case $last_cache_state in
        100)        if (( time_since_last_deployment < hotfix_period )) ; then
                        exit 1
                    elif (( time_since_last_deployment < maintenance_period )) ; then
                        cache_state=101
                    fi
                    ;;
        101)        if (( time_since_last_deployment < maintenance_period )) ; then
                        exit 1
                    fi
                    ;;
        102)        exit 1 # stay stable.
                    ;;
        initial|*)  # Cover the case where the previous commit's cache policy implemented different states
                    if [[ "${GITHUB_ACTIONS:-no}" == true ]] ; then
                        # Just allow the build, GitHub Pages are not rebuilt on cron
                        # because setting headers is not supported; policy can't work.
                        cache_state=0
                    elif (( time_since_last_deployment < hotfix_period )) ; then
                        cache_state=100
                    elif (( time_since_last_deployment < maintenance_period )) ; then
                        cache_state=101
                        hotfix_after="ended"
                        maintenance_after=$(date -d "+$maintenance_period_desc -$time_since_last_deployment seconds")
                        cache_policy="Maintenance-ready"
                    fi
                    ;;
    esac
    if [[ ! ${cache_state:+isset} ]] ; then
        cache_state=102
    fi
fi

format_duration() {
  local seconds=$1
  local days=$((seconds / 86400))
  local hours=$(( (seconds % 86400) / 3600 ))
  local minutes=$(( (seconds % 3600) / 60 ))
  local secs=$((seconds % 60))

  local result=""
  if [ $days -gt 0 ]; then
    result+="${days}d"
  fi
  if [ $hours -gt 0 ]; then
    result+="${hours}h"
  fi
  if [ $minutes -gt 0 ]; then
    result+="${minutes}m"
  fi
  if [ $secs -gt 0 ] || [ -z "$result" ]; then
    result+="${secs}s"
  fi

  echo "$result"
}

# Select the support and cache times from the UNBUST_CACHE_SUPPORT and
# UNBUST_CACHE_TIME arrays, depending of the policy decision ($cache_state)
selectSupportAndCacheTime()
{
    local state=$1
	local cache_times=($UNBUST_CACHE_TIME)
	local support_times=($UNBUST_CACHE_SUPPORT)

	if (( state == 0 || (state >= 100 && state < 119) )) ; then
		local idx
		if [[ $state != 0 ]] ; then
			idx=$((state - 100))
		else
			idx=0
		fi
		if [[ "${GITHUB_ACTIONS:-no}" == true ]] ; then
			# Github pages does not support custom headers
			cache_time=0
		elif [[ "${VERCEL:-no}" == 1 ]] ; then
			# Vercel does not support headers generated at build time.
			# Assume the default (0) will be used.
			# If you set cache time for the entry points in your vercel.json
			# modify this to use the same value
			# possibly using $(jq .headers.xxxx vercel.json)
			cache_time=0
		else
			cache_time=${cache_times[$idx]:-${cache_times[0]}}
		fi
		support_time=${support_times[$idx]:-${support_times[0]}}
    fi

    hotfix_cache_time=${cache_times[0]:-${cache_times[0]}}
    hotfix_cache_time_desc=$(format_duration $hotfix_cache_time)

    maintenance_cache_time=${cache_times[1]:-${cache_times[0]}}
    maintenance_cache_time_desc=$(format_duration $maintenance_cache_time)

    stable_cache_time=${cache_times[2]:-${cache_times[0]}}
    stable_cache_time_desc=$(format_duration $stable_cache_time)
}

# ############# Prepare feedback for demo page ############################
# The last_deployment calculation is not correct because it samples current time,
# which can be off compared to the sample taken in unbust.sh.
# The difference can be a second or more depending on the time it take unbust.sh
# to fetch and populate deprecated assets.
#
# I could fix it by making the 2nd argument an absolute time, but that would
# make the interface less elegant.
#
# I'm keeping the interface elegant, and live with a few seconds of discrepancy
# in the demo.
#
# If this bothers you in your own application, feel free to change it in your
# fork.
# #####################################################
function date() {
    local datestr
    datestr=$(command date "$@")
    echo "<span class="udate">$datestr</span>"
}
case $cache_state in
    100)
            hotfix_after=$(date -d "$NOW")
            maintenance_after=$(date -d "$NOW +$hotfix_period_desc")
            stable_after="not before $(date -d "$NOW +$hotfix_period_desc +$maintenance_period_desc")"
            cache_policy="Hotfix-ready"
            last_deployment=$(date -d "$NOW")
            ;;
    101)
            hotfix_after="ended"
            maintenance_after=$(date -d "$NOW")
            stable_after=$(date -d "$NOW +$maintenance_period_desc")
            cache_policy="Maintenance-ready"
            last_deployment=$(date -d "$NOW -$time_since_last_deployment seconds")
            ;;
    102)
            hotfix_after="ended"
            maintenance_after="ended"
            stable_after="now"
            cache_policy="Stable"
            last_deployment=$(date -d "$NOW -$time_since_last_deployment seconds")
            ;;
    0)
            hotfix_after="n/a"
            maintenance_after="n/a"
            stable_after="n/a"
            cache_policy="n/a"
            last_deployment=$(date -d "$NOW")
            ;;
esac

case $cache_state in
    0)
            policy_table_class="cache-policy-unsupported"
            policy_impossible_class="cache-policy-container"
            ;;
    *)
            policy_table_class="cache-policy-container"
            policy_impossible_class="cache-policy-unsupported"
    ;;
esac

selectSupportAndCacheTime $cache_state

# ############# Set CDN configuration ############################
versioned_assets_cache_param="max-age=63072000, immutable"
entry_point_cache_param="max-age=$cache_time"
if [[ "${CF_PAGES:-no}" == 1 ]] ; then
  cat >> $output_dir/_headers <<EOF

# Versioned presentation assets
/*.css
  Cache-Control: $versioned_assets_cache_param

/favicon.ico
  Cache-Control: $versioned_assets_cache_param

# This is information, must be timely, minimal cache
/subdir/*.txt
  Cache-Control: max-age=120

# Unversioned presentation assets
/subdir/unversioned-file
  Cache-Control: max-age=31536000, must-revalidate

/edge-cached-1-minute/*
  Cache-Control: s-maxage=60, max-age=300, immutable

# Unversioned presentation entry-point
/
  Cache-Control: $entry_point_cache_param

# Unversioned presentation entry-point
/subdir/
  Cache-Control: $entry_point_cache_param

EOF

elif [[ "${GITHUB_ACTIONS:-no}" == true ]] ; then
    cache_policy="cache management not-supported on GitHub Pages"
    sed --in-place '
        s@cache-policy-container@cache-policy-container hidden@;
    ' $output_dir/index.html

elif [[ "${NETLIFY:-no}" == true ]] ; then
  cat >> $output_dir/netlify.toml <<EOF

# Versioned presentation assets
[[headers]]
  for = "/*.css"
  [headers.values]
  Cache-Control: $versioned_assets_cache_param

[[headers]]
  for = /favicon.ico
  [headers.values]
  Cache-Control: $versioned_assets_cache_param

# This is information, must be timely, minimal cache
[[headers]]
  for = /subdir/*.txt
  [headers.values]
  Cache-Control: max-age=120

# Unversioned presentation assets
[[headers]]
  for = /subdir/unversioned-file
  [headers.values]
  Cache-Control: max-age=31536000, must-revalidate

[[headers]]
  for = /edge-cached-1-minute/*
  [headers.values]
  Cache-Control: s-maxage=60, max-age=300, immutable

# Unversioned presentation entry-point
[[headers]]
  for = /
  [headers.values]
  Cache-Control: $entry_point_cache_param

# Unversioned presentation entry-point
[[headers]]
  for = /subdir/
  [headers.values]
  Cache-Control: $entry_point_cache_param

EOF
elif [[ "${VERCEL:-no}" == 1 ]] ; then
  cat >> vercel.json <<EOF
{
  "headers": [
    { "source": "/*.css",
      "headers": [{ "key": "Cache-Control", "value": "$versioned_assets_cache_param" }]},
    { "source": "/favicon.ico",
      "headers": [{ "key": "Cache-Control", "value": "$versioned_assets_cache_param" }]},
    { "source": "/subdir/*.txt",
      "headers": [{ "key": "Cache-Control", "value": "max-age=120" }]},
    { "source": "/subdir/unversioned-file",
      "headers": [{ "key": "Cache-Control", "value": "max-age=31536000, must-revalidate" }]},
    { "source": "/edge-cached-1-minute/*",
      "headers": [{ "key": "Cache-Control", "value": "s-maxage=60, max-age=300, immutable" }]},
    { "source": "/",
      "headers": [{ "key": "Cache-Control", "value": "$entry_point_cache_param" }]},
    { "source": "/subdir/",
      "headers": [{ "key": "Cache-Control", "value": "$entry_point_cache_param" }]}
  ]
}
EOF

fi

# ############# Update Demo page ############################
#
# Instead of updating a page, you might use these variables to notify your team
# or set calendar reminders of when the hotfix and maintenance windows close.
# ie, email/slack/calendar/etc.
#
sed --in-place '
    s@_CACHE_POLICY_@'"$cache_policy"'@g;
    s@_ENTRY_CACHE_TIME_@'"$cache_time"'@g;
    s@_HOTFIX_AFTER_@'"$hotfix_after"'@g;
    s@_MAINTENANCE_AFTER_@'"$maintenance_after"'@g;
    s@_STABLE_AFTER_@'"$stable_after"'@g;
    s@_HOTFIX_CACHE_TIME_@'"$hotfix_cache_time_desc"'@g;
    s@_MAINTENANCE_CACHE_TIME_@'"$maintenance_cache_time_desc"'@g;
    s@_STABLE_CACHE_TIME_@'"$stable_cache_time_desc"'@g;
    s@_LAST_DEPLOYMENT_@'"$last_deployment"'@g;
    s@_POLICY_TABLE_CLASS_@'"$policy_table_class"'@g;
    s@_POLICY_IMPOSSIBLE_CLASS_@'"$policy_impossible_class"'@g;
    s@_UNBUST_CACHE_TIME_@'"$UNBUST_CACHE_TIME"'@g;
    s@_UNBUST_CACHE_SUPPORT_@'"$UNBUST_CACHE_SUPPORT"'@g;
    s@_DEPLOYED_TIME_@'"$NOW"'@g;
    s@_SUPPORT_TIME_@'"$support_time"'@g;
    s@_VERSIONED_ASSETS_HEADER_@Cache-Control: '"$versioned_assets_cache_param"'@g;
    s@_ENTRY_POINT_HEADER_@Cache-Control: '"$entry_point_cache_param"'@g;
    ' $output_dir/index.html

# ############# Return the cache state decision to unbust.sh #############
exit $cache_state
