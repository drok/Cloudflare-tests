#!/bin/bash

output_dir="/tmp/out"
# Local testing
if [ "${DEBSIGN_KEYID}" == "8F5713F1" ] ; then
    TEST_SHA="377adeb59f3f3256d7ddee3e2e9ca09361507bd4"
fi

LINK_PUBLISHED_HISTORY_TO_SOURCE_HISTORY=1

unset SOURCE_COMMIT_SHA

set -o errexit

[[ ${output_dir:+isset} ]]

# Local testing
if [ "${DEBSIGN_KEYID}" == "8F5713F1" ] ; then
    rm -rf "${output_dir}"
fi

PUBLIC_URL="https://cloudflare-tests.pages.dev"
DEFAULT_CACHE_UNBUST_TIME="3 minutes ago"

NOW=$(date +%s)
# NOW=$(command date --date="2020-06-01" "+%s")

date() {
    command date --date=@$NOW "$@"
}

git() {
    command git -C "${CACHE_UNBUST_KEY}" "$@"
}

deprecation_setup() {
    local dburl="$1"

    # GIT_DIR=${CACHE_UNBUST_KEY:-}

    export GIT_COMMITTER_DATE=$NOW GIT_AUTHOR_DATE=$NOW GIT_DIR=.git

    if [ ${CF_PAGES:+isset} ] ; then
        export GIT_ALTERNATE_OBJECT_DIRECTORIES=$REPO_DIR/.git/objects
        SOURCE_COMMIT_SHA="$CF_PAGES_COMMIT_SHA"
    else
        # Local testing
        if [ "${DEBSIGN_KEYID}" == "8F5713F1" ] ; then
            export GIT_ALTERNATE_OBJECT_DIRECTORIES=$WORKDIR/.git/objects
            if [ ${TEST_SHA:+isset} ] ; then
                SOURCE_COMMIT_SHA="$TEST_SHA"
            fi
        fi
    fi

    # Ensure CACHE_UNBUST_KEY is set. There is no default, because it should be
    # secret
    [[ ${CACHE_UNBUST_KEY:+isset} ]]
set -x
    if [ ! -d "${CACHE_UNBUST_KEY}" ] ; then
        # mkdir -p "${CACHE_UNBUST_KEY}"
        command git -c init.defaultBranch=published init --template=/dev/null "${CACHE_UNBUST_KEY}"
        git config pack.packSizeLimit 20m
        git config commit.gpgSign false
        git config gc.pruneExpire now
        git config user.name "Archivium Cache Bot"
        git config user.email "unbust-cache-script@archivium.org"
        git remote add "$remotename" "${dburl}/${CACHE_UNBUST_KEY}/$GIT_DIR"

        # Local testing
        if [ "${DEBSIGN_KEYID}" == "8F5713F1" ] ; then
            git remote set-url "$remotename" "${output_dir}.public/${CACHE_UNBUST_KEY}/$GIT_DIR"
            rsync -a "${output_dir}.public/${CACHE_UNBUST_KEY}/$GIT_DIR" "${CACHE_UNBUST_KEY}/"
        fi
        # End local testing

        if [ "${DEBSIGN_KEYID}" == "8F5713F1" ] ; then
            :
        else
            if ! git fetch "$remotename" ; then
                git commit --allow-empty -m "Initial commit"
            else
                git checkout "$branchname"
                git remote remove "$remotename"
            fi
        fi
    fi
}

# Fetch from the currently published version of the site the files which are
# deprecated
deprecation_refill() {
    local dburl="$1"
    local obs=${CACHE_UNBUST_TIME:-$DEFAULT_CACHE_UNBUST_TIME} obstime

    if ! obstime=$(date --date="$obs" "+%s") ; then
        obstime=$(date --date="$DEFAULT_CACHE_UNBUST_TIME" "+%s")
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
                if ! wget --retry-connrefused --input-file=$list --base="$dburl" -o "$wgetlog" ; then
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
    # be stored in the $CACHE_UNBUST_KEY directory at that location
    local dburl="$1"
    local msg="${2:-Published $(sitestats)}"

    # Implentation choices
    local branchname=published
    local remotename=public

    # Ensure we know where the persistent DB is kept
    [[ ${dburl:+isset} ]] 

    deprecation_setup "${dburl}"

    find -type f \! -path "./${CACHE_UNBUST_KEY}/*" -printf '%P\n' >"${CACHE_UNBUST_KEY}"/files

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
    else
        git commit -m "$msg" || :
    fi

# set +x
    git gc --quiet
    git pack-refs --all --prune
    git update-server-info

    # Local testing
    if [ "${DEBSIGN_KEYID}" == "8F5713F1" ] ; then
        git log --graph --oneline --all
    fi

    deprecation_refill "${dburl}"
}

FN=$(command date "+%F %H%M%S")

if [ ${CF_PAGES:+isset} ] ; then
    DEPRECATION_MESSAGE="Published ${CF_PAGES_BRANCH} (${CF_PAGES_COMMIT_SHA::8}) at ${CF_PAGES_URL}"
else
    DEPRECATION_MESSAGE=""
fi


mkdir -p $output_dir
WORKDIR=$PWD
cd $output_dir

echo hello >"$output_dir/$FN"
mkdir $output_dir/subdir
echo hello >"$output_dir/subdir/$FN"

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