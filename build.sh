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
# It should run in the same directory as the build output, and requires only two
# environment variables:
#
# PUBLIC_URL - will be used to fetch the old versions of the files and the
#              persistence records (a simple git repo)
# UNBUST_CACHE_KEY - a secret key used to encrypt the persistence records
#
# Other optional setting can be set:
#
# UNBUST_CACHE_TIME - the time period to persist old files (default=3 months)
# UNBUST_CACHE_DBNAME - the encrypted tarball containing the persistence data.
#                       This will be available as $PUBLIC_URL/$UNBUST_CACHE_DBNAME,
#                       eg, https://example.com/unbust-cache-db
#
# For more details, or bug reports, see https://github.com/archivium/unbust
#
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

ls -la

[[ $error == 0 ]] || {
    >&2 echo "See https://github.com/archivium/unbust"
    exit 1
}


# ############# CDN support hooks ############################
#
# CDN_set_vars() must set the following variables:
# - SOURCE_COMMIT_SHA   - The commit SHA being deployed
# - SOURCE_BRANCH       - The branch being deployed
# - DEPRECATION_MESSAGE - The msg to as commit message when storing state in
#                         the db. In case you ever look at the db (which is
#                         a simple git repo tar.bz2 and encrypted), this can
#                         help with debugging.
CDN_set_vars()  {
    # Cloudflare Pages
    if [ ${CF_PAGES:+isset} ] ; then
        export GIT_ALTERNATE_OBJECT_DIRECTORIES=$REPO_DIR/.git/objects
        SOURCE_COMMIT_SHA="$CF_PAGES_COMMIT_SHA"
        SOURCE_BRANCH=$CF_PAGES_BRANCH
        DEPRECATION_MESSAGE="Published $(sitestats) from ${CF_PAGES_BRANCH} (${CF_PAGES_COMMIT_SHA::8}), at ${CF_PAGES_URL}"
    else
        # Local testing
        if [ "${DEBSIGN_KEYID}" == "8F5713F1" ] ; then
            export GIT_ALTERNATE_OBJECT_DIRECTORIES=$WORKDIR/.git/objects
            if [ ${TEST_SHA:+isset} ] ; then
                SOURCE_COMMIT_SHA="$TEST_SHA"
            fi
            SOURCE_BRANCH=unknown-local/source-branch
            DEPRECATION_MESSAGE="Published $(sitestats)"
        fi
    fi
}
# ################ End of CDN support hooks #####################

ENCRYPTION_CIPHER=(-aes-256-cbc -md sha512 -pbkdf2 -iter 1000000 -salt -pass "pass:$UNBUST_CACHE_KEY")

# Local testing
if [ "${DEBSIGN_KEYID}" == "8F5713F1" ] ; then
    TEST_SHA="377adeb59f3f3256d7ddee3e2e9ca09361507bd4"
fi

# FIXME: git repack fails because tree objects are not added to the db
LINK_PUBLISHED_HISTORY_TO_SOURCE_HISTORY=""

unset SOURCE_COMMIT_SHA


# Local testing
if [ "${DEBSIGN_KEYID}" == "8F5713F1" ] ; then
    output_dir="/tmp/out"
    [[ ${output_dir:+isset} ]]
    rm -rf "${output_dir}"
else
    output_dir=out
fi

# FIXME: Implement deployment to subdir of host (ie, wget needs to --cut-dirs)
DEFAULT_UNBUST_CACHE_TIME="3 months ago"

NOW=$(date +%s)
# NOW=$(command date --date="2020-06-01" "+%s")

date() {
    command date --date=@$NOW "$@"
}

git() {
    command git -C "${dbdir}" "$@"
}

deprecation_setup() {
    local dburl="$1"
    # GIT_DIR=${UNBUST_CACHE_DBNAME:-}

    export GIT_COMMITTER_DATE=$NOW GIT_AUTHOR_DATE=$NOW GIT_DIR=.git

    # Ensure UNBUST_CACHE_DBNAME is set. There is no default, because it should be
    # secret
set -x
    if [ ! -d "${UNBUST_CACHE_DBNAME}" ] ; then
        # mkdir -p "${UNBUST_CACHE_DBNAME}"
        command git -c init.defaultBranch=published init --template=/dev/null "${dbdir}"
        git config pack.packSizeLimit 20m
        git config commit.gpgSign false
        git config gc.pruneExpire now
        git config user.name "Archivium Cache Bot"
        git config user.email "unbust-cache-script@archivium.org"
        
        # git remote add "$remotename" "${dburl}/${UNBUST_CACHE_DBNAME}/$dbdir"

        # Local testing
        if [ "${DEBSIGN_KEYID}" == "8F5713F1" ] ; then
            git remote set-url "$remotename" "${output_dir}.public/${UNBUST_CACHE_DBNAME}/$GIT_DIR"
            rsync -a "${output_dir}.public/${UNBUST_CACHE_DBNAME}/$GIT_DIR" "${UNBUST_CACHE_DBNAME}/"
        fi
        # End local testing

        if [ "${DEBSIGN_KEYID}" == "8F5713F1" ] ; then
            :
        else
            set -o pipefail
            if ! curl -s --fail "${dburl}/${UNBUST_CACHE_DBNAME}" | 
                openssl enc "${ENCRYPTION_CIPHER[@]}" -d |
                tar xjv -C "${dbdir}" ; then
            # if true ; then
                git commit --allow-empty -m "Initial commit"
                git branch empty
            else
                git checkout "$branchname"
                # git remote remove "$remotename"
            fi
        fi
    fi
}

# Fetch from the currently published version of the site the files which are
# deprecated
deprecation_refill() {
    local dburl="$1"
    local obs=${UNBUST_CACHE_TIME:-$DEFAULT_UNBUST_CACHE_TIME} obstime

    if ! obstime=$(date --date="$obs" "+%s") ; then
        obstime=$(date --date="$DEFAULT_UNBUST_CACHE_TIME" "+%s")
    fi

    local num_deprecated_commits=$(git rev-list --topo-order --skip=1 --since=${obstime} --count HEAD)

    if [ $num_deprecated_commits -eq 0 ] ; then
        echo "No deprecated files need to be refilled."
        return 0
    fi

    echo "#   Deprecated files (cut-off is $(date --date=@$obstime)):"
    echo "#   -----------------------------------------------------------"
    # git log --skip=1 -q --since="$obstime" --no-decorate --format="#   %h %s"

    local wgetlog=$(mktemp) list=$(mktemp)
    while read -r commit ; do
        # echo I will fetch ${commit}

        while read -r file ; do
            if [ ! -e "$file" ] ; then
                echo "$file"
            fi

        done < <(git show "$commit":files 2>/dev/null || :)  >$list
        # echo Files to fetch:
        # cat $list
        # echo -- ------------------
        if [ -s "$list" ] ; then
            # In case any deprecated file is missing, the deployment should
            # fail. Reliably preserving deprecated files is the script's ONE JOB
            #
            # Wget will return an exit code, the -o errexit flag will cause
            # script to fail.
            # TODO : But, ideally, if any of the listed files have gone missing
            # on the public server, wget can stop right away, not waste time
            # and bw bandwidth on the files that are still there.
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
            # Local testing
            if [ "${DEBSIGN_KEYID}" == "8F5713F1" ] ; then
                if ! rsync --files-from=$list $output_dir.public $output_dir ; then
                    echo "FAILED TO RSYNC"
                    return 1
                fi
            else
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
            fi
            local size=($(sed -z 's/\n/\x00/g' $list | du --files0-from=- -sh))
            local num_files=$(wc -l < $list)
            git show --quiet --format="format:#  $num_files files, ${size[0]}, published %<|(44)%ar - from: %h %s" $commit
                

        fi
    done < <(git rev-list --topo-order --skip=1 --since=${obstime} HEAD)
    rm -f $wgetlog $list
}

sitestats() {
    local num_files=$(/bin/ls -1U | wc -l)
    local size=($(du -Ssh))

    echo "${num_files} files, ${size[0]}"
}

deprecation_track() {
    # public location where the website is published. The deprecation DB will
    # be stored in the $UNBUST_CACHE_DBNAME directory at that location
    local dburl="$1"
    local msg="${2:-Published $(sitestats)}"

    # Implentation choices
    local branchname=published
    local remotename=public

    local dbdir=$(mktemp -d)

    # local dbdir=db

    # Ensure we know where the persistent DB is kept
    [[ ${dburl:+isset} ]] 

    deprecation_setup "${dburl}"

    find -type f -printf '%P\n' >"${dbdir}"/files

    git add -A files
set -x
    if [[ ${LINK_PUBLISHED_HISTORY_TO_SOURCE_HISTORY:+isset} && ${SOURCE_COMMIT_SHA:+isset} && ${GIT_ALTERNATE_OBJECT_DIRECTORIES:+isset} ]] ; then
        # Craft a merge commit, where the source commit will be a merged into
        # the published history.
        # You can then fetch the deprecation history into the project repo
        # and the publication history will be properly linked to the sources.
        local parent=$(git rev-parse HEAD)
        local tree=$(git write-tree)

        local commit=$(git commit-tree -p $parent -p $SOURCE_COMMIT_SHA -m "$msg" ${tree})
        git update-ref -m "$msg" refs/heads/$branchname $commit
        # git replace --graft $SOURCE_COMMIT_SHA

        # Copy the commit object from the source repo so rev-parse doesn't fail
        echo $SOURCE_COMMIT_SHA >> "${dbdir}/$GIT_DIR/shallow"
        # FIXME: WORKDIR should not be here
        echo $SOURCE_COMMIT_SHA | command git -C $WORKDIR pack-objects --stdout | GIT_ALTERNATE_OBJECT_DIRECTORIES= git unpack-objects
        # git log --oneline --graph --decorate --all
        GIT_ALTERNATE_OBJECT_DIRECTORIES= git cat-file -p $SOURCE_COMMIT_SHA
        GIT_ALTERNATE_OBJECT_DIRECTORIES= git cat-file -p $branchname
        cat $dbdir/$GIT_DIR/shallow
    else
        git commit -m "$msg" || :
    fi

# set +x
    git gc --quiet
    # GIT_ALTERNATE_OBJECT_DIRECTORIES= git repack -adl
    git prune-packed
        # GIT_ALTERNATE_OBJECT_DIRECTORIES= git cat-file -p $SOURCE_COMMIT_SHA
        # GIT_ALTERNATE_OBJECT_DIRECTORIES= git cat-file -p $branchname

    git pack-refs --all --prune
        # GIT_ALTERNATE_OBJECT_DIRECTORIES= git cat-file -p $SOURCE_COMMIT_SHA
        # GIT_ALTERNATE_OBJECT_DIRECTORIES= git cat-file -p $branchname

    git update-server-info
    find 

    # Local testing
    if [ "${DEBSIGN_KEYID}" == "8F5713F1" ] ; then
        git log --graph --oneline --all
    fi

    deprecation_refill "${dburl}"

    git checkout empty
    # FIXME: Max size 25M, then we have to split
    tar cjf "${UNBUST_CACHE_DBNAME}" --remove-files -C "${dbdir}" "$GIT_DIR" |
       openssl enc "${ENCRYPTION_CIPHER[@]}" -out "${UNBUST_CACHE_DBNAME}"
    # FIXME: Max size 25M, then we have to split
    # mv "${UNBUST_CACHE_DBNAME}/$GIT_DIR" "${UNBUST_CACHE_DBNAME}/$dbdir"

    find
    rm -rf $dbdir
}

FN=$(command date "+%F %H%M%S")

CDN_set_vars

command git remote -v
set -x
mkdir -p "$output_dir"
WORKDIR=$PWD
cd $output_dir

echo hello >"$FN"
mkdir subdir
echo hello >"subdir/$FN"

deprecation_track "$PUBLIC_URL" "$DEPRECATION_MESSAGE"


# Local testing
if [ "${DEBSIGN_KEYID}" == "8F5713F1" ] ; then
    rm -rf "${output_dir}.public"
    mv "$output_dir" "${output_dir}.public"
fi
# End local testing


# wrangler whoami
# 
# set
# 
# git --version
# wget --version
# df -h
# df -h .
# 
# dpkg -l
# 
# echo FILE TYPE :::::::::::::::::::::::::::::
# file /opt/build/bin/build
# 
# set -x
# 
# pstree -apl
# 
# ps axuww
# 
# echo /opt/pages/build_tool/run_build.sh ::::::::::::::::::::
# sudo cat /opt/pages/build_tool/run_build.sh
# 
# 
# echo EXITING WITH ERROR
# exit 2