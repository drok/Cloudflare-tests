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

hotfix_cache_time=600
hotfix_cache_time_desc="10 minutes"

maintenance_cache_time=$((3600 * 24))
maintenance_cache_time_desc="1 day"

stable_cache_time=$((3600 * 24 * 7))
stable_cache_time_desc="1 month"

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

if [[ "${GITHUB_ACTIONS:-no}" == true ]] ; then
    # Just allow the build, GitHub Pages are not rebuilt on cron
    # because setting headers is not supported; policy can't work.
    cache_state=0
elif [[ $is_redeployement == 0 ]] ; then
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
                        cache_time=$maintenance_cache_time
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
            cache_time=$hotfix_cache_time
            hotfix_after=$(date -d "$NOW")
            maintenance_after=$(date -d "$NOW +$hotfix_period_desc")
            stable_after="not before $(date -d "$NOW +$hotfix_period_desc +$maintenance_period_desc")"
            cache_policy="Hotfix-ready"
            last_deployment=$(date -d "$NOW")
            ;;
    101)
            cache_time=$maintenance_cache_time
            hotfix_after="ended"
            maintenance_after=$(date -d "$NOW")
            stable_after=$(date -d "$NOW +$maintenance_period_desc")
            cache_policy="Maintenance-ready"
            last_deployment=$(date -d "$NOW -$time_since_last_deployment seconds")
            ;;
    102)
            cache_time=$stable_cache_time
            hotfix_after="ended"
            maintenance_after="ended"
            stable_after="now"
            cache_policy="Stable"
            last_deployment=$(date -d "$NOW -$time_since_last_deployment seconds")
            ;;
    0)
            cache_time="GitHub Pages defaults"
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

# ############# Set CDN configuration ############################
if [[ "${CF_PAGES:-no}" == 1 ]] ; then
  cat >> $output_dir/_headers <<EOF

# Versioned presentation assets
/*.css
  Cache-Control: max-age=63072000, immutable

/favicon.ico
  Cache-Control: max-age=63072000, immutable

# This is information, must be timely, minimal cache
/subdir/*.txt
  Cache-Control: max-age=120

# Unversioned presentation assets
/subdir/unversioned-file
  Cache-Control: max-age=31536000, must-revalidate

# Unversioned presentation entry-point
/
  Cache-Control: max-age=$cache_time

# Unversioned presentation entry-point
/subdir/
  Cache-Control: max-age=$cache_time

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
  Cache-Control: max-age=63072000, immutable

[[headers]]
  for = /favicon.ico
  [headers.values]
  Cache-Control: max-age=63072000, immutable

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

# Unversioned presentation entry-point
[[headers]]
  for = /
  [headers.values]
  Cache-Control: max-age=$cache_time

# Unversioned presentation entry-point
[[headers]]
  for = /subdir/
  [headers.values]
  Cache-Control: max-age=$cache_time

EOF
elif [[ "${VERCEL:-no}" == 1 ]] ; then
  cat >> vercel.json <<EOF
{
  "headers": [
    { "source": "/*.css",
      "headers": [{ "key": "Cache-Control", "value": "max-age=63072000, immutable" }]},
    { "source": "/favicon.ico",
      "headers": [{ "key": "Cache-Control", "value": "max-age=63072000, immutable" }]},
    { "source": "/subdir/*.txt",
      "headers": [{ "key": "Cache-Control", "value": "max-age=120" }]},
    { "source": "/subdir/unversioned-file",
      "headers": [{ "key": "Cache-Control", "value": "max-age=31536000, must-revalidate" }]},
    { "source": "/",
      "headers": [{ "key": "Cache-Control", "value": "max-age=$cache_time" }]},
    { "source": "/subdir/",
      "headers": [{ "key": "Cache-Control", "value": "max-age=$cache_time" }]}
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
    s@_CACHE_POLICY_@'"$cache_policy"'@;
    s@_ENTRY_CACHE_TIME_@'"$cache_time"'@;
    s@_HOTFIX_AFTER_@'"$hotfix_after"'@;
    s@_MAINTENANCE_AFTER_@'"$maintenance_after"'@;
    s@_STABLE_AFTER_@'"$stable_after"'@;
    s@_HOTFIX_CACHE_TIME_@'"$hotfix_cache_time_desc"'@;
    s@_MAINTENANCE_CACHE_TIME_@'"$maintenance_cache_time_desc"'@;
    s@_STABLE_CACHE_TIME_@'"$stable_cache_time_desc"'@;
    s@_LAST_DEPLOYMENT_@'"$last_deployment"'@;
    s@_POLICY_TABLE_CLASS_@'"$policy_table_class"'@;
    s@_POLICY_IMPOSSIBLE_CLASS_@'"$policy_impossible_class"'@;
    s@_UNBUST_CACHE_TIME_@'"$UNBUST_CACHE_TIME"'@;
    ' $output_dir/index.html

# ############# Return the cache state decision to unbust.sh #############
exit $cache_state
