#!/bin/bash

# ############## Unbust cache v.1.0.0 ###############
#
# This script persists files published to a CDN across builds, for a given
# period of time (UNBUST_CACHE_TIME, default=3 months)
#
# It should be used together with filenames containing build ID (eg,
# "myapp.89abcd.min.js"). Without this persistence, when new versions are
# published, browsers that still request the old files would receive 404's
# 
# The persistence ensures that active user sessions, which can last for months
# or longer, can still find the resources they need, even if the published
# website includes newer versions of the same resources.
#
# It requires two arguments and two environment variables:
#
# Arguments:
#    unbust.sh <outputdir> <initial commit hash> [cache logic script]
#       <outputdir> - The directory where the files to be published are
#                    (the build output directory). It can be relative.
#       <initial commit hash> - The commit hash in the source repo that is
#                    first "unbusted". The script will initialize the tracking
#                    DB, but only if the currently deployed commit matches this
#                    in order to avoid accidentally reinitializing the DB due
#                    to misconfiguration or other errors.
#       [cache logic script] - (optional) A script that takes two arguments and
#                    returns a caching decision as exit code. See "Cache Logic"
#                    below.
#
# Environment:
#
#       PUBLIC_URL - will be used to fetch the old versions of the files and the
#                   persistence records (a simple git repo)
#       UNBUST_CACHE_KEY - a secret key used to encrypt the persistence records
#
# Other optional setting can be set:
#
#       UNBUST_CACHE_TIME - the time period to persist old files
#                   (default=3 months)
#       UNBUST_CACHE_DBNAME - the encrypted tarball filename containing the
#                   persistence database. This will be available as
#                   $PUBLIC_URL/$UNBUST_CACHE_DBNAME, (default=unbust-cache-db)
#                       eg, "my-unbust-db"
#
# Cache logic:
#
#       If a "cache logic script" is given as the third argument on the command
#       line, it will be called before the persisted files are fetched. This
#       script can be used to generate a _headers configuration containing
#       "Cache-Control" headers, for example, according to some policy.
#
#       The script is called with two arguments:
#           1. "0" if the currently deployed source commit is the different
#              than the previous deployment, or "1" if it is a repeat deployment
#           2. The time in second since the previous deployment.
#           3. The previous cache policy applied, or "initial" if it's the first
#              deployment with a cache policy script present. This will be the
#              same numeric code previously returned by the cache policy script
#              (ie, 0 or 100-119)
#
#       The script should return one of the following exit codes:
#           0 - All good, no cache policy was applied
#           1 - Deployment should be aborted
#           100 - "Hotfix-ready"
#           101 - "Maintenance-ready"
#           102 - "Stable"
#           103-119 - custom
#
# The unbust script doesn't do anything with this policy code than store it
# in the persistence DB, and supply it on the following deployment. It's up to
# the cache logic script to decide how to use it, or what codes mean.
#
# Suggested cache logic (assuming CI/CD implements a cron job to call
# deployment periodically):
#
# When deploying a new source commit (1st arg is "0"), assume the website is
# broken, and take a "hotfix-ready" stance. The entry-point (index.html, etc)
# should be minimally cached, possibly 10 minutes or so. All versioned files
# can use normal (stable) settings. If a hotfix is required, roll the versions
# of the versioned assets, and overwrite the entry-point.
#
# When deploying a repeat commit (1st arg is "1"), depending on how long it's
# been since the previous deployment, the cache settings can be relaxed.
# If it's been less than 1 week since the last deployment, abort the repeat
# deployment by returning 1.
# After 1 week in "hotfix-ready", switch to "maintenance-ready".
# There is no emergency, but some undiscovered bugs may still exist.
# A medium cache time for the entry point is appropriate, possibly 1 day or so,
# meaning that after a bug has been been fixed and deployed, users of the
# site may still see the buggy version for up to a day.
# If the bug fix turns out to break the site, at least it will be unleashed
# over a 1 day, rather than quickly.
# After 3 weeks in maintenance-ready, switch to "stable".
# This is the longest cache times that are appropriate. The "stable" cache time
# normally depends on when you plan the next release, and how quickly you will
# expect the rollout to be. Eg, a one month cache time means your users will
# see the old version for up to a month after the new release is deployed.
# It also gives you breathing room. If the next release turns out to be
# a disaster, at least you will dissapoint only 1/30 of your users each day,
# making the eventual hotfix less urgent. OTOH, a short cache time means if you
# screw up the next release, everyone will know right away.
# 
# The return value of 0 is no different than the 100-119 range. The deployemnt
# will continue as normal. You could take it to mean "the policy script ran,
# but made no caching decisions" (ie, the CDN's default caching policy was
# in force).
# 
#
# The script automatically trims the persistence history as needed to prevent
# it from growing indefinitely. If you want too keep the full persistence
# locally, you can download it with the fetch more ("unbust.sh -f"). It takes
# environment variables, and creates or updates a git repo in the current
# directory, setting up a remote named "cdn" to keep the
# refs/remotes/cdn/published branch history. This can be done either as part of
# your release process, or periodically with cron.
#
# 
# For more details, or bug reports, see https://github.com/archivium/unbust
#
# Typical CDN deployment build cmdline example (ie, run unbust.sh after output
# is generated):
#        npm run build && ../tools/unbust.sh out a7ec317
# ##########################################################################

error=0

# Required control variables:
[[ ${UNBUST_CACHE_KEY:+isset} ]] || {
	>&2 echo "ERROR: UNBUST_CACHE_KEY is not set."
	error=1
}

[[ ${PUBLIC_URL:+isset} ]] || {
	>&2 echo "ERROR: PUBLIC_URL is not set."
	error=1
}

# Optional control variables:
[[ ${UNBUST_CACHE_DBNAME:+isset} ]] || {
	UNBUST_CACHE_DBNAME=unbust-cache-db
}

[[ ${UNBUST_CACHE_TIME:+isset} ]] || {
	UNBUST_CACHE_TIME="3 months ago"
}
# ############# End of configuration #########################

set -o errexit
set -o pipefail

[[ $error == 0 ]] || {
	>&2 echo "See https://github.com/archivium/unbust"
	exit 1
}


# ############# CDN support hooks ############################
#
# CDN_set_vars() must set the following variables:
# - DEPRECATION_MESSAGE - The msg to as commit message when storing state in
#                         the db. In case you ever look at the db (which is
#                         a simple git repo tar.bz2 and encrypted), this can
#                         help with debugging.
# - SOURCE_COMMIT_SHA   - The commit hash of the source repo that is deployed
# - DEPLOYED_AT_URL		- The URL of the deployed site
CDN_set_vars()  {
	# Cloudflare Pages
	if [ ${CF_PAGES:+isset} ] ; then
		DEPRECATION_MESSAGE="Published $(sitestats) from ${CF_PAGES_BRANCH}"
		SOURCE_COMMIT_SHA=$CF_PAGES_COMMIT_SHA
		DEPLOYED_AT_URL=$CF_PAGES_URL
	else
		>&2 echo "ERROR: This CDN is not yet supported."
		return 1
		DEPRECATION_MESSAGE="Published $(sitestats)"
	fi
}
# ################ End of CDN support hooks #####################

ENCRYPTION_CIPHER=(-aes-256-cbc -md sha512 -pbkdf2 -iter 1000000 -salt -pass "pass:$UNBUST_CACHE_KEY")


# FIXME: git repack fails because tree objects are not added to the db

# FIXME: Implement deployment to subdir of host (ie, wget needs to --cut-dirs)
DEFAULT_UNBUST_CACHE_TIME="3 months ago"

NOW=$(date +%s)

date() {
	command date --date=@$NOW "$@"
}

git() {
	command git -C "${dbdir}" "$@"
}

deprecation_setup() {
	local dburl="$1"

	export GIT_COMMITTER_DATE=$NOW GIT_AUTHOR_DATE=$NOW GIT_DIR=.git

	if [ -f "${UNBUST_CACHE_DBNAME}" ] ; then
		>&2 echo "ERROR: A file named '${UNBUST_CACHE_DBNAME}' (UNBUST_CACHE_DBNAME) already exists in the output directory."
		>&2 echo "       Set UNBUST_CACHE_DBNAME to another filename or remove the offending file from the output"
		exit 1
	fi
		
	local fetch_status
	local tmp=$(mktemp)
	if ! fetch_status=$(curl -L --fail -H "Cache-control: no-cache, private" --write-out "%{http_code}" -o $tmp "${dburl}/${UNBUST_CACHE_DBNAME}") ; then
	
		if [[ $fetch_status == "000" ]] ; then
			>&2 echo "ERROR: The persistence database could not be fetched from '${dburl}/${UNBUST_CACHE_DBNAME}'."
			>&2 echo "       If it's a network error, try again later. Is the hostname correct?"
			exit 1
		fi

		# If the db is empty, create a new one
		# But prevent inadventently resetting persistence state due to
		# misconfiguration or a network error
		pushd
		local HEAD initial_sha
		if ! HEAD=$(command git rev-parse HEAD) || ! initial_sha=$(command git rev-parse $INITIAL_COMMIT_SHA) || [ "$HEAD" != "$initial_sha" ]; then

			>&2 echo "ERROR: The persistence database could not be fetched."
			>&2 echo "       Refusing to create a new one because the initial commit hash is not the same as the current commit."
			if [[ $fetch_status == 404 ]] ; then
				>&2 echo "       No persistence DB exists at ${dburl}/${UNBUST_CACHE_DBNAME} (404)."
				>&2 echo "       This is a configuration error (PUBLIC_URL mismatch?)"
			else
				>&2 echo "       If it's a network error, try again later. Curl said ($fetch_status)."
			fi
			exit 1
		fi
		pushd
		command git -c init.defaultBranch=published init --quiet --template=/dev/null "${dbdir}"
		git config pack.packSizeLimit 20m
		git config commit.gpgSign false
		git config gc.pruneExpire now
		git config core.logAllRefUpdates false
		git config user.name "Archivium Cache Bot"
		git config user.email "unbust-bot@archivium.org"
		git commit --allow-empty -m "Initial commit"
		git branch empty
	else
		if ! openssl enc "${ENCRYPTION_CIPHER[@]}" -d -in $tmp |
			tar xj -C "${dbdir}" ; then
			>&2 echo "ERROR: The persistence database could not be decrypted."
			>&2 echo "       This is a configuration error (UNBUST_CACHE_KEY mismatch?)"
			>&2 echo "       To create a new DB set $HEAD as initial-sha argument to the script."
			exit 1
		fi
		git checkout -q "$publish_branch"
	fi
	rm -f $tmp
}

# Fetch from the currently published version of the site the files which are
# deprecated
deprecation_refill() {
	local dburl="$1"
	local obs=${UNBUST_CACHE_TIME:-$DEFAULT_UNBUST_CACHE_TIME} obstime

	if ! obstime=$(date --date="$obs" "+%s") ; then
		obstime=$(date --date="$DEFAULT_UNBUST_CACHE_TIME" "+%s")
	fi

	# Trim DB to only the relevant history. This ensures that increasing the UNBUST_CACHE_TIME does
	# not result in errors due to already missing files.
	# It also keeps the size of the DB from growing
	git pull --shallow-since=${obstime} .

	local num_deprecated_commits=$(git rev-list --topo-order --skip=1 --since=${obstime} --count HEAD)

	if [ $num_deprecated_commits -eq 0 ] ; then
		echo "No deprecated files need to be refilled."
		return 0
	fi

	echo "#   Deprecated files (cut-off is $(date --date=@$obstime)):"
	echo "#   -----------------------------------------------------------"

	local wgetlog=$(mktemp) list=$(mktemp)
	while read -r commit ; do

		while read -r file ; do
			if [ ! -e "$file" ] ; then
				echo "$file"
			fi
		done < <(git show "$commit":files 2>/dev/null || :)  >$list

		if [ -s "$list" ] ; then
			# In case any deprecated file is missing, the deployment should
			# fail. Reliably preserving deprecated files is the script's ONE JOB
			#
			# Wget will return an exit code, the -o errexit flag will cause
			# script to fail.
			# TODO : But, ideally, if any of the listed files have gone missing
			# on the public server, wget can stop right away, not waste time
			# and bandwidth on the files that are still there. An incomplete
			# persistence is a deployment failure.
			#
			# Recovery - the deployment can be tried again. Maybe the missing
			# files come back, or enough time passes that a the missing files
			# become obsolete and are no longer needed.
			#
			# Otherwise, the site admin can push the missing files.
			# Otherwise, some other strategy is needed, that would tell browsers
			# that how to recover graciously from the missing files (perhaps
			# a hard refresh)
			#
			# Failing to preserve deprecated files is a failure. This script
			# has ONE JOB, and that is it.
			#
			# FIXME: If through some mapping, the deployed files appear in a subdirectory,
			# need to cut some directories
			if ! wget --retry-connrefused --recursive --no-host-directories --input-file=$list --base="$dburl" -o "$wgetlog" ; then
				echo "# ##########################################################"
				echo "# #######  Failed to download deprecated files: ############"
				echo "# ##########################################################"
				cat $wgetlog
				echo "# ##########################################################"
				return 1
			fi
			local size=($(sed -z 's/\n/\x00/g' $list | du --files0-from=- -sh))
			local num_files=$(wc -l < $list)
			git show --quiet --format="format:#  $num_files files, ${size[0]}, published %<|(44)%ar - from: %h %s" $commit
			echo ""
		fi
	done < <(git rev-list --topo-order --skip=1 --since=${obstime} HEAD)
	rm -f $wgetlog $list
}

sitestats() {
	local num_files=$(/bin/ls -1U | wc -l)
	local size=($(du -Ssh))

	echo "${num_files} files, ${size[0]}"
}

unset cache_state_msg
trailers=()
record_caching_state() {
	local cache_logic_script=$1
	local last_commit_time=$2
	local cache_state="initial"
	local same_source_sha=0

	if [[ ${SOURCE_COMMIT_SHA:+isset} ]] ; then
		while read -r trailer content ; do
			case ${trailer,,} in
				source)
					if [[ $content == ${SOURCE_COMMIT_SHA::10} ]] ; then
								same_source_sha=1
					fi
					;;
				cache) cache_state=$content
					;;
			esac
		done < <(git show -s --no-decorate | git interpret-trailers --parse --trim-empty)
	fi

	pushd
	$cache_logic_script $same_source_sha $last_commit_time $cache_state && cache_state=$? || cache_state=$?
	pushd

	case $cache_state in
		100) cache_state_msg="Hotfix-ready"
		;;
		101) cache_state_msg="Maintenance-ready"
		;;
		102) cache_state_msg="Stable"
		;;
	esac
set -x
	if (( cache_state == 0 || (cache_state >= 100 && cache_state < 119) )) ; then
		if [[ ${cache_state_msg:+isset} ]] ; then
			trailers+=(--trailer "Cache: $cache_state - ${cache_state_msg}")
		else
			trailers+=(--trailer "Cache: ${cache_state}")
		fi

		# if git checkout $cache_branch ; then
		# 	git merge --no-edit -m "$cache_state_msg" "$publish_branch"
		# else
		# 	git checkout -b $cache_branch
		# 	git commit --allow-empty -m "$cache_state_msg"
		# fi
	elif [[ $cache_state == 1 ]] ; then
		>&2 echo "ERROR: Deployment rejected by cache policy script $cache_logic_script."
		exit 1
	else
		>&2 echo "ERROR: Cache policy script $cache_logic_script failed ($cache_state)."
		exit 1
	fi
set +x
}

# Implentation choices
publish_branch=published
cache_branch=caching
deprecation_track() {
	# public location where the website is published. The deprecation DB will
	# be stored in the $UNBUST_CACHE_DBNAME directory at that location
	local dburl="$1"
	local msg="${2:-Published $(sitestats)}"
	local cache_logic_script=$3

	# Implentation choices
	local remotename=public

	local dbdir=$(mktemp -td unbust-db.XXXXXX)

	deprecation_setup "${dburl}"

	find -type f -printf '%P\n' >"${dbdir}"/files

	git add -A files

set -x
	local last_commit_time
	if [[ ${cache_logic_script:+isset} ]] ; then
		last_commit_time=$(git log -1 --format=%at)
	fi

	if [[ ${last_commit_time:+isset} ]] ; then
		record_caching_state "$cache_logic_script" "$((NOW - last_commit_time))"
	fi

	if [[ ${SOURCE_COMMIT_SHA:+isset} ]] ; then
		trailers+=(--trailer "Source: ${SOURCE_COMMIT_SHA::10}")
	fi
	if [[ ${#trailers[@]} -gt 0 ]] ; then
		msg=$(echo "$msg" | git interpret-trailers "${trailers[@]}")
	fi
set +x
	git commit -q --allow-empty -m "$msg"

	git gc --quiet
	git prune-packed
	git pack-refs --all --prune
	git update-server-info

	deprecation_refill "${dburl}"

	git show -p
	git checkout -q empty

	# FIXME: Max size 25M, then we have to split
	tar cj --remove-files -C "${dbdir}" "$GIT_DIR" |
	   openssl enc "${ENCRYPTION_CIPHER[@]}" -out "${UNBUST_CACHE_DBNAME}"

	rm -rf $dbdir
}

fetch_repo() {
	local dburl="$1"

	local fetch_status
	local tmp=$(mktemp)
	if ! fetch_status=$(curl -s -L --fail -H "Cache-control: no-cache, private" --write-out "%{http_code}" -o $tmp "${dburl}/${UNBUST_CACHE_DBNAME}") ; then
	
		if [[ $fetch_status == "000" ]] ; then
			>&2 echo "ERROR: The persistence database could not be fetched from '${dburl}/${UNBUST_CACHE_DBNAME}'."
			>&2 echo "       If it's a network error, try again later. Is the hostname correct?"
			exit 1
		fi

		>&2 echo "       No persistence DB exists at ${dburl}/${UNBUST_CACHE_DBNAME} (404)."
		exit 1
	elif [ ! -d  .git ] ; then
		if ! openssl enc "${ENCRYPTION_CIPHER[@]}" -d -in $tmp |
			tar xj .git/; then
				>&2 echo "ERROR: The persistence database could not be decrypted."
				>&2 echo "ERROR: The persistence database could not be decrypted."
				exit 1
		fi
		command git remote add cdn "${dburl}"
		command git checkout -q "$publish_branch"
	else
		if ! openssl enc "${ENCRYPTION_CIPHER[@]}" -d -in $tmp |
			tar xj --transform "s@\.git/packed-refs@.git/packed-refs.cdn@" .git/objects/pack .git/packed-refs ; then
				>&2 echo "ERROR: The persistence database could not be decrypted."
				>&2 echo "       This is a configuration error (UNBUST_CACHE_KEY mismatch?)"
				exit 1
		fi
		local remote_branch=($(grep "refs/heads/$publish_branch" .git/packed-refs.cdn))
		if [[ "${#remote_branch[@]}" == 2 ]] ; then
			mkdir -p .git/refs/remotes/cdn
			echo ${remote_branch[0]} > .git/refs/remotes/cdn/$publish_branch
			command git merge --ff-only cdn/$publish_branch
		fi
	fi
	rm -f $tmp
}

usage() {
	echo "Usage: $0 [-f] <output directory> <initial commit hash>"
	echo "  -f  Fetch the repo into the current dir (eg, for record keeping)"
	echo "  -h  Show this help"
}

unset opt OPTARG
OPTIND=1
while getopts ":fh" opt ; do
	case $opt in
		f) fetch_repo "$PUBLIC_URL"
		exit 0
				;;
		h) usage
				exit 0
				;;
		\?) >&2 echo "Invalid option: -$OPTARG"
				;;
		:) >&2 echo "Option -$OPTARG requires an argument in ${FUNCNAME[0]}."
				;;
	esac
done

[[ $# -lt 2 ]] && {
	usage
	exit 1
}

[ -d "$1" ] || {
	>&2 echo "Not a directory: $1"
	exit 1
}

if [[ $# -ge 3 ]] ; then
	type $3 2>/dev/null 2>&1 || {
		>&2 echo "Cache policy script not found or not executable ($3)"
		exit 1
	}
fi

pushd "$1"

INITIAL_COMMIT_SHA="$2"

CDN_set_vars

deprecation_track "$PUBLIC_URL" "$DEPRECATION_MESSAGE" "${3:-}"
