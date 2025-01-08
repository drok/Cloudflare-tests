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
#    unbust.sh <outputdir> <initial commit hash>
#       <outputdir> - The directory where the files to be published are
#                    (the build output directory). It can be relative.
#       <initial commit hash> - The commit hash in the source repo that is
#                    first "unbusted". The script will initialize the tracking
#                    DB, but only if the currently deployed commit matches this
#                    in order to avoid accidentally reinitializing the DB due
#                    to misconfiguration or other errors.
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
CDN_set_vars()  {
	# Cloudflare Pages
	if [ ${CF_PAGES:+isset} ] ; then
		DEPRECATION_MESSAGE="Published $(sitestats) from ${CF_PAGES_BRANCH} (${CF_PAGES_COMMIT_SHA::8}), at ${CF_PAGES_URL}"
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
		git checkout -q "$branchname"
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

# Implentation choices
branchname=published
deprecation_track() {
	# public location where the website is published. The deprecation DB will
	# be stored in the $UNBUST_CACHE_DBNAME directory at that location
	local dburl="$1"
	local msg="${2:-Published $(sitestats)}"

	# Implentation choices
	local remotename=public

	local dbdir=$(mktemp -td unbust-db.XXXXXX)

	deprecation_setup "${dburl}"

	find -type f -printf '%P\n' >"${dbdir}"/files

	git add -A files

	git commit -q --allow-empty -m "$msg"

	git gc --quiet
	git prune-packed
	git pack-refs --all --prune
	git update-server-info

	deprecation_refill "${dburl}"

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
		command git checkout -q "$branchname"
	else
		if ! openssl enc "${ENCRYPTION_CIPHER[@]}" -d -in $tmp |
			tar xj --transform "s@\.git/packed-refs@.git/packed-refs.cdn@" .git/objects/pack .git/packed-refs ; then
				>&2 echo "ERROR: The persistence database could not be decrypted."
				>&2 echo "       This is a configuration error (UNBUST_CACHE_KEY mismatch?)"
				exit 1
		fi
		local remote_branch=($(grep "refs/heads/$branchname" .git/packed-refs.cdn))
		if [[ "${#remote_branch[@]}" == 2 ]] ; then
			mkdir -p .git/refs/remotes/cdn
			echo ${remote_branch[0]} > .git/refs/remotes/cdn/$branchname
			command git merge --ff-only cdn/$branchname
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

[[ $# -ne 2 ]] && {
	usage
	exit 1
}

[ ! -d "$1" ] && {
	>&2 echo "Not a directory: $1"
}

pushd "$1"

INITIAL_COMMIT_SHA="$2"

CDN_set_vars

deprecation_track "$PUBLIC_URL" "$DEPRECATION_MESSAGE"
