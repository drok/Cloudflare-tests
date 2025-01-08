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
NOW=$(date -u +%d%H%M)
if [[ ${NOW::5} == "03020" ]] ; then
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
                    if (( time_since_last_deployment < hotfix_period )) ; then
                        cache_state=100
                    elif (( time_since_last_deployment < maintenance_period )) ; then
                        cache_state=101
                        cache_time=$maintenance_cache_time
                        hotfix_till="ended"
                        maintenance_till=$(date -d "+$maintenance_period_desc -$time_since_last_deployment seconds")
                        cache_policy="Maintenance-ready"
                    fi
                    ;;
    esac
    if [[ ! ${cache_state:+isset} ]] ; then
        cache_state=102
    fi
fi

# ############# Prepare feedback for demo page ############################
case $cache_state in
    100)
            cache_time=$hotfix_cache_time
            hotfix_till=$(date -d "+$hotfix_period_desc -$time_since_last_deployment seconds")
            maintenance_till=$(date -d "+$maintenance_period_desc +$hotfix_period_desc -$time_since_last_deployment seconds")
            cache_policy="Hotfix-ready"
            ;;
    101)
            cache_time=$maintenance_cache_time
            hotfix_till="ended"
            maintenance_till=$(date -d "+$maintenance_period_desc -$time_since_last_deployment seconds")
            cache_policy="Maintenance-ready"
            ;;
    102)
            cache_time=$stable_cache_time
            hotfix_till="ended"
            maintenance_till="ended"
            cache_policy="Stable"
            ;;
esac

# ############# Set CDN configuration ############################
if [[ "${CF_PAGES}" == 1 ]] ; then
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
  Cache-Control: max-age=$cache_time, immutable

# Unversioned presentation entry-point
/subdir/
  Cache-Control: max-age=$cache_time, immutable

EOF
fi

# ############# Update Demo page ############################
#
# Instead of updating a page, you might use these variables to notify your team
# or set calendar reminders of when the hotfix and maintenance windows close.
# ie, email/slack/calendar/etc.
#
sed --in-place '
    s/_CACHE_POLICY_/'"$cache_policy"'/;
    s/_HOTFIX_TILL_/'"$hotfix_till"'/;
    s/_MAINTENANCE_TILL_/'"$maintenance_till"'/;
    s/_HOTFIX_CACHE_TIME_/'"$hotfix_cache_time_desc"'/;
    s/_MAINTENANCE_CACHE_TIME_/'"$maintenance_cache_time_desc"'/;
    s/_STABLE_CACHE_TIME_/'"$stable_cache_time_desc"'/;
    s/_LAST_DEPLOYMENT_/'"$(date -d "+$time_since_last_deployment seconds")"'/;
    ' $output_dir/index.html

# ############# Return the cache state decision to unbust.sh #############
exit $cache_state
