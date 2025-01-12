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
#       UNBUST_CACHE_KEY - a secret key used to encrypt the persistence records
#       CF_BUG_756652_WORKAROUND - Required only on Cloudflare Pages. two word
#					setting. First word: Production Environemnt branch name,
#                   Second word: project URL (at pages.dev).
#                   Eg. for this project (`unbust`), the Production branch for
#                   the demo site is `unbust/demo`, so the correct setting is
#					CF_BUG_756652_WORKAROUND="unbust/demo https://unbust.pages.dev"
# See https://community.cloudflare.com/t/branch-alias-url-for-pages-production-env/756652
#
#
#
# Other optional setting can be set:
#
#       UNBUST_CACHE_SUPPORT - time in days that the release will be supported
#                   This can be a list of
#                   periods if cache policy is implemented, one period
#                   for each policy mode. The first figure is considered
#                   the fallback period. Otherwise, the first corresponds to
#                   policy 100, the second to policy 101 and so on.
#                   Default: 90 (ie, 3 months)
#
#       UNBUST_CACHE_TIME - cache time in seconds that the entry points (*.html)
#
#                   should be cached (ie, the max-time arg of Cache-Control: headers)
#                   This can be a list of cache times if cache policy is implemented,
#                   one cache time for each policy mode. The first is a fallback, and each
#                   figure corresponds to a policy, as UNBUST_CACHE_SUPPORT above.
#                   Default: 86400 (ie, 1 day)
#
#       UNBUST_CACHE_DBNAME - the encrypted tarball filename containing the
#                   persistence database. This will be available as
#                   $BRANCH_URL/$UNBUST_CACHE_DBNAME,
#                       eg, "my-unbust-db"
# 					Default: unbust-cache-db
#
# Cache logic:
#
#       If a "cache logic script" is given as the third argument on the command
#       line, it will be called before the persisted files are fetched. This
#       script can be used to generate a _headers configuration containing
#       "Cache-Control" headers, for example, according to some policy.
#
#       The script is called with four arguments:
#           1. "0" if the currently deployed source commit is the different
#              than the previous deployment, or "1" if it is a repeat deployment
#           2. The time in seconds since the previous successful deployment.
#           3. The previous cache policy applied, or "initial" if it's the first
#              deployment with a cache policy script present. This will be the
#              same numeric code previously returned by the cache policy script
#              (ie, 0 or 100-119)
#           4. output directory
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

# Optional control variables:
[[ ${UNBUST_CACHE_DBNAME:+isset} ]] || {
	UNBUST_CACHE_DBNAME=unbust-cache-db
}

[[ ${UNBUST_CACHE_SUPPORT:+isset} ]] || {
	UNBUST_CACHE_SUPPORT=90 # 3 months.
}

[[ ${UNBUST_CACHE_TIME:+isset} ]] || {
	UNBUST_CACHE_TIME=$(( 24 * 3600 )) # one day, in seconds
}
# ############# End of configuration #########################

set -o errexit
set -o pipefail
set -o nounset

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
# - DEPLOYED_AT_URL		- The URL of the deployed site for this commit
# - BRANCH_URL          - The URL where the branch is deployed
#                         Note: For Cloudflare, this must be set in the
#						  calling environment. It cannot be detected
# - BRANCH				- Branch name
CDN_set_vars()  {

	# Cloudflare Pages
	if [[ ${CF_PAGES:+isset} ]] ; then
		DEPRECATION_MESSAGE="Published $(sitestats) from ${CF_PAGES_BRANCH}"
		SOURCE_COMMIT_SHA=${CF_PAGES_COMMIT_SHA::12}
		# replace non-alphanums with dashes in branch Alias URL
		# https://developers.cloudflare.com/pages/configuration/preview-deployments/#preview-aliases
		# https://community.cloudflare.com/t/branch-alias-url-for-pages-production-env/756652
		# On Cloudflare Pages, a branch URL Alias is not available for Production builds (if Preview Deployments are disabled)
		# See community discussion above.
		# This workaround should work for both preview and production.
		# Set the Environment variable CF_BUG_756652_WORKAROUND to contain both the production branch name and the
		# project URL, which is what the branch URL would point to. Example:
		# CF_BUG_756652_WORKAROUND="release https://my-project.pages.dev"
		if [[ ${CF_BUG_756652_WORKAROUND:+isset} ]] ; then
			local cf_production_branch_alias_params=($CF_BUG_756652_WORKAROUND)
			if [[ ${cf_production_branch_alias_params[0]} == ${CF_PAGES_BRANCH} ]] ; then
				BRANCH_URL=${cf_production_branch_alias_params[1]}
			else
				local escaped_branch=$(echo $CF_PAGES_BRANCH | sed 's@[^[:alnum:]]@-@g;')
				BRANCH_URL=$(echo $CF_PAGES_URL | sed -r "s@https://\\w+.@https://$escaped_branch.@")
			fi
		else
			local escaped_branch=$(echo $CF_PAGES_BRANCH | sed 's@[^[:alnum:]]@-@g;')
			BRANCH_URL=$(echo $CF_PAGES_URL | sed -r "s@https://\\w+.@https://$escaped_branch.@")
		fi
		DEPLOYED_AT_URL=$CF_PAGES_URL # This is a deployment-unique url
		BRANCH=$CF_PAGES_BRANCH

	# GitHub Pages
	elif [[ ${GITHUB_ACTIONS:+isset} ]] ; then
		DEPRECATION_MESSAGE="Published $(sitestats) from ${GITHUB_REF}"
		SOURCE_COMMIT_SHA=${GITHUB_SHA::12}
		BRANCH_URL=$(gh api "repos/$GITHUB_REPOSITORY/pages" --jq '.html_url')
		DEPLOYED_AT_URL=$BRANCH_URL
		BRANCH=$GITHUB_REF
	
	# Netlify
	elif [[ ${NETLIFY:+isset} ]] ; then
		DEPRECATION_MESSAGE="Published $(sitestats) from ${BRANCH}"
		SOURCE_COMMIT_SHA=${COMMIT_REF::12}
		BRANCH_URL=$DEPLOY_PRIME_URL
		DEPLOYED_AT_URL=$DEPLOY_URL
		# BRANCH is already set by Netfly

	# Vercel
	elif [[ ${VERCEL:+isset} ]] ; then
		DEPRECATION_MESSAGE="Published $(sitestats) from ${VERCEL_GIT_COMMIT_REF}"
		SOURCE_COMMIT_SHA=${VERCEL_GIT_COMMIT_SHA::12}
		BRANCH_URL=https://$VERCEL_BRANCH_URL
		DEPLOYED_AT_URL=$BRANCH_URL
		BRANCH=$VERCEL_GIT_COMMIT_REF
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
DEFAULT_UNBUST_CACHE_TIME=90

NOW=$(date +%s)

date() {
	command date --date=@$NOW "$@"
}

git() {
	command git --no-pager -C "${dbdir}" "$@"
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
		pushd >/dev/null
		local HEAD initial_sha
		if ! HEAD=$(command git rev-parse HEAD) || ! initial_sha=$(command git rev-parse $INITIAL_COMMIT_SHA) || [ "$HEAD" != "$initial_sha" ]; then

			>&2 echo "ERROR: The persistence database could not be fetched."
			>&2 echo "       Refusing to create a new one because the initial commit hash is not the same as the current commit."
			if [[ $fetch_status == 404 ]] ; then
				>&2 echo "       No persistence DB exists at ${dburl}/${UNBUST_CACHE_DBNAME} (404)."
				>&2 echo "       This is a configuration error (BRANCH_URL mismatch?)"
			else
				>&2 echo "       If it's a network error, try again later. Curl said ($fetch_status)."
			fi
			exit 1
		fi
		pushd >/dev/null
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
	# Get the path depth of the BRANCH_URL, so wget can --cut-dirs
	local urldepth=$(python3 -c "import os, urllib.parse; from pathlib import Path; print(len(Path(urllib.parse.urlparse(\"$dburl\").path.strip(\"/\")).parents))")
	# local obs=${UNBUST_CACHE_TIME:-$DEFAULT_UNBUST_CACHE_TIME} obstime

	#if ! obstime=$(date --date="$obs" "+%s") ; then
	#	obstime=$(date --date="$DEFAULT_UNBUST_CACHE_TIME" "+%s")
	#fi

#	local num_deprecated_commits=$(git rev-list --topo-order --skip=1 --since=${obstime} --count HEAD)
#
#	if [ $num_deprecated_commits -eq 0 ] ; then
#		echo "No deprecated files need to be refilled."
#		return 0
#	fi

	local diagout

	if [[ ${UNBUST_CACHE_DIAG:+isset} ]] ; then
		# FIXME: If no cache-policy script is given, there is no project_name or cache_state_name

		if [[ "$UNBUST_CACHE_DIAG" =~ \.html$ ]] ; then
			diagout="${UNBUST_CACHE_DIAG}"
		else
			diagout="diag.html"
		fi
		sed  "
			s@_BRANCH_@$BRANCH@g;
			s@_PROJECT_@$project_name@g;
			/data-webframes/q;" "$srcdir/diag.html" > "$diagout"
cat >>"$diagout" <<-EOF
		${project_name}, ${cur_cache_state_name}, $DEPLOYED_AT_URL
		$(date +%F) > $(command date --date @$(( NOW + cur_support_time * 24 * 3600 + 2 * cur_cache_time )) +%F)
EOF
		find -type f -name "*.html" -printf '%P\n' >>"$diagout"
		echo "" >>"$diagout"

	fi

	echo "#   Deprecated files:"
	echo "#   -----------------------------------------------------------"

	local wgetlog=$(mktemp) list=$(mktemp)
	local trim_cutoff
	# When was the replacement deployment made
	local replacement_time=$NOW deployment_time
	while read -r commit ; do

		# Calculate if this deployment ($commit) is deprecated or obsolete
		local cache_state support_time cache_time commit_url deploy_sha trailer
		local project_name cache_state_name
		local a b c d unused
		while read -r trailer a b c d unused ; do
			echo "looking at ${trailer,,}"
			case ${trailer,,} in
				project:) project_name=($a $b $c $d $unused)
						project_name="${project_name[*]}"
						;;
				state:) cache_state_name=($a $b $c $d $unused)
						cache_state_name="${cache_state_name[*]}"
						;;
				unbust:) cache_state=$a support_time=$b cache_time=$c deploy_sha=$d
					;;
				url:) commit_url=$a
					;;
				# TODO: recover the commit deployment URL and use it for fetching.
				# The problem: the last deployed fileset may include files from a newer
				# deployment that has since become obsolete (eg, from a hotfix now expired)
				# Fetching from the commit deployment URL will get the correct file,
				# but possibly a different/older file that was last deployed at the branch
				# deployment URL. The website might work with the hotfix file (from branch
				# deployment URL), but not with the "proper" file, from the correct commit
				# deployment URL.
				# Not implementing this because it seems more wise to preserve last
				# state rather than correct it.
			esac
		done < <(git show -s --format=format:%B --no-decorate $commit | git interpret-trailers --parse --trim-empty)

#		git show -s --format=format:%B --no-decorate $commit
		# This deployment commit is supported if the next/replacement deployment is less than
		# 2*$cache_time old (ie, the cached entry-point is still valid),
		# or the deployment time is less than $support_time old (ie, open tabs still need it)
		#
		# 2 * cache_time means: After end of support, after replacement was deployed, browser
		# fetches a copy from edge, which is up to "cache_time" out-of-date,
		# and uses it for another "cache_time", meaning the browser will access resources for
		# the replaced deployment up to 2 * cache_time after the deployment.

		deployment_time=$(git show -s --format=%at $commit)
#		if (( NOW - replacement_time >= (2 * cache_time) )) ; then
#			echo "______________ Commit $commit is obsolete because $NOW - $replacement_time > 2 * $cache_time (out of cache)"
#		fi
#		if (( NOW - deployment_time >= (support_time * 24 * 3600) )) ; then
#			echo "______________ Commit $commit is obsolete because $NOW - $deployment_time > $support_time days (out of support)"
#		fi

		local end_of_support last_cache_read obsolete_time
		end_of_support=$(( deployment_time + support_time * 24 * 3600 ))
		last_cache_read=$(( replacement_time + 2 * cache_time ))
		if (( end_of_support > last_cache_read )) ; then
			obsolete_time=$end_of_support
		else
			obsolete_time=$last_cache_read
		fi
		if (( NOW >= obsolete_time )) ; then
			replacement_time=$deployment_time
			continue
		fi

		# low watermark - the earliest useful deployment commit
		trim_cutoff=$commit

		# If it has "files"
		if git show "$commit":files >/dev/null 2>&1 ; then
			if [[ ${diagout:+isset} ]] ; then
				# TODO: Cleanup the $BRANCH/$cache_state defaults, they are temporary because teh
				# existing persist DB was created before the Project: and State: trailers
				cat >>$diagout <<-EOF
				${project_name:-$BRANCH}, ${cache_state_name:-$cache_state}, $commit_url, $deploy_sha
				$(command date --date @$deployment_time +%F) > $(command date --date @$obsolete_time +%F)
	EOF
				git show "$commit":files 2>/dev/null | egrep \\.html\$ >> $diagout
			fi

			# Get a list of (deprecated) files that need to be fetched
			while read -r file ; do
				# Make a list of files to be preserved from the branch URL
				if [ ! -e "$file" ] ; then
					echo "$file"
				fi

				local diagfile
				# Fetch diagnostic entry points from the commit URL
				if [[ ${diagout:+isset} && "$file" =~ .*\.html$ ]] ; then
					echo "$file" >> $diagout
					diagfile=${file/%.html/.${deploy_sha::7}.html}
					if [ ! -e "$diagfile" ] ; then
						if ! wget --cut-dirs=$urldepth--retry-connrefused --force-directories --no-host-directories "$commit_url/$file" -O "$diagfile" -o "$wgetlog" &&
							! wget --cut-dirs=$urldepth--retry-connrefused --force-directories --no-host-directories "$dburl/$diagfile" -O "$diagfile" -a "$wgetlog" ; then
							>&2 echo "# ##########################################################"
							>&2 echo "# #  Failed to fetch diag file: $commit_url/$file"
							>&2 echo "# ##########################################################"
							>&2 cat $wgetlog
							>&2 echo "# ##########################################################"
							return 1
						fi
					fi
				fi
			done < <(git show "$commit":files) >$list
			echo "" >> $diagout
		fi

		replacement_time=$deployment_time

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

			if ! wget --cut-dirs=$urldepth--retry-connrefused --recursive --no-host-directories --input-file=$list --base="$dburl" -o "$wgetlog" ; then
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
	done < <(git rev-list --topo-order --skip=1 HEAD)

	# Trim DB to only the relevant history.
	# git --no-pager log --graph --all
	# trim_cutoff=7d44daff589c6a557f9c6d26a4bd49e3d73031f1
	if [[ ${trim_cutoff:+isset} ]] ; then echo $trim_cutoff > $dbdir/.git/shallow ; fi
	rm -f $wgetlog $list
	if [[ ${diagout:+isset} ]] ; then
		sed -n -e '/END-OF-DATA/,$p' "$srcdir/diag.html" >>$diagout
	fi

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
	local outdir=$3
	local cache_state="initial"
	local is_redeployement=0

	local cache_times=($UNBUST_CACHE_TIME)
	local support_times=($UNBUST_CACHE_SUPPORT)

	local cache_state support_time cache_time commit_url deploy_sha trailer
	while read -r trailer cache_state support_time cache_time deploy_sha unused ; do
		case ${trailer,,} in
			unbust:) break
				;;
		esac
	done < <(git show -s --format=format:%B --no-decorate | git interpret-trailers --parse --trim-empty)
	if [[ "$deploy_sha" == "$SOURCE_COMMIT_SHA" ]] ; then
				is_redeployement=1
	fi

	pushd >/dev/null
	local policy_response=$(mktemp)
	$cache_logic_script $is_redeployement $last_commit_time ${cache_state:-0} "$outdir" "$policy_response" && cache_state=$? || cache_state=$?
	pushd >/dev/null

	if (( cache_state == 0 || (cache_state >= 100 && cache_state < 119) )) ; then
		# Read policy response
		# vars are declared in the caller, and also used in deprecation_refill
		# to update the diag file
		{
			local magic
			read -r magic
			[[ "$magic" == "Unbust Policy Response file v1" ]] || {
				>&2 echo "ERROR: Policy response format not supported."
				exit 1
			}
			read -r project_name
			read -r cur_cache_state_name
			read -r cur_support_time cur_cache_time cur_phase_time
		} < "$policy_response"
		trailers+=(
			--trailer "Project: $project_name"
			--trailer "State: $cur_cache_state_name"
			--trailer "Unbust: $cache_state $cur_support_time $cur_cache_time $SOURCE_COMMIT_SHA"
			--trailer "Url: $DEPLOYED_AT_URL"
		)

		# if git checkout $cache_branch ; then
		# 	git merge --no-edit -m "$cache_state_msg" "$publish_branch"
		# else
		# 	git checkout -b $cache_branch
		# 	git commit --allow-empty -m "$cache_state_msg"
		# fi
	elif [[ $cache_state == 1 ]] ; then
		>&2 echo "ERROR: Deployment rejected by cache policy script \"$cache_logic_script $is_redeployement $last_commit_time $cache_state\"."
		exit 1
	else
		>&2 echo "ERROR: Cache policy script $cache_logic_script failed ($cache_state)."
		exit 1
	fi
	rm -f "$policy_response"
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
	local outdir=$4

	# Implentation choices
	local remotename=public

	local dbdir=$(mktemp -td unbust-db.XXXXXX)

	deprecation_setup "${dburl}"

	find -type f -printf '%P\n' >"${dbdir}"/files

	git add -A files

	local last_commit_time
	if [[ ${cache_logic_script:+isset} ]] ; then
		last_commit_time=$(git --no-pager log -1 --format=%at)
	fi

	# Declared here and shared between record_caching_state and deprecation_refill
	# cur_ means currently decided by policy
	local project_name cur_cache_state_name
	local cur_cache_time cur_support_time cur_phase_time

	record_caching_state "$cache_logic_script" "$((NOW - last_commit_time))" "$outdir"

	if [[ ${#trailers[@]} -gt 0 ]] ; then
		msg=$(echo "$msg" | git interpret-trailers "${trailers[@]}")
	fi

	git commit -q --allow-empty -m "$msg"
	git show -s

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
		f) fetch_repo "$BRANCH_URL"
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
	type $3 >/dev/null 2>&1 || {
		>&2 echo "Cache policy script not found or not executable ($3)"
		exit 1
	}
fi

pushd "$1" >/dev/null
srcdir=$OLDPWD

INITIAL_COMMIT_SHA="$2"

CDN_set_vars

deprecation_track "$BRANCH_URL" "$DEPRECATION_MESSAGE" "${3:-}" "$1"
