#!/bin/bash
# This script belongs to the VIBE project
#
# It checks the provided repository for changes, builds new and changed application
# containers and updates the menu of the desktop.
# Every container version present in the repository is kept in the environment. A version is
# retired once its definition is moved to the repository's 'archive' folder: on production the
# image is moved to the shared archive, on development and testing it is deleted.
# For automated building, this script requires an access token with checkout permissions
# to be either passed as parameter or within a credential file (containing the REPO_USER and REPO_TOKEN variables).
# All variables of this script can be set by providing a config file, with settings passed as argument taking precedence. 

# Location of the shared VIBE folder
VIBE_PATH_DEFAULT="/storage/research/dsl_vibe_rs"
# URL base of the repository to build from
REPO_BASE_DEFAULT="https://github.com/dsl-unibe-ch"
# Path of the repo on the local filesystem
REPO_PATH=${VIBE_PATH}/repos/
# Config file providing script variables (can provide any of the  variable)
CONFIGFILE=
# Branch of the repo to build (default: 'main' / 'build' for dev) set during environment-specific setup below)
BRANCH=""
# timestamp
DATE=$(date +%Y%m%d)
# Error flag
ERROR_FLAG='false'
# Use a lock file so the script is only ran once (set per stage below)
LOCKFILE=""
# Variables the config file may provide are left empty here and defaulted after it was parsed,
# otherwise the 'parameter wins over config' check below would always see them as already set.
# Debug output
DEBUG=
# Don't do a full build by default
FULL_BUILD=
# Also build containers that have a definition in the repository but no image yet
BUILD_MISSING=
# Allow lock file to be ignored
FORCE_RUN=
# Environment to build for (default: derived from the repo name, see below)
STAGE=
# Existing checkout of the applications repo to build from instead of cloning / pulling
LOCAL_REPO=

# abort script on error
set -e

# function for trap to ignore errors in certain conditions
ignore_errors() {
  echo "Error during container build."
}

# Copy a container image into the shared archive and remove it from the environment once verified
archive_image() {
  local image=$1
  local filename=$(basename $image)
  local name=${filename%.sif}
  local application=$(cut -d '-' -f1 <<< $name)
  local grouping=$(cut -d '-' -f 1-2 <<< $name)
  local label_date=$(apptainer inspect $image 2>/dev/null | grep org.label-schema.build-date | awk '{print $2}' | sed 's/_/ /g')
  local build_date=$(date -d "$label_date" +%Y%m%d 2>/dev/null)

  # Fall back to the file date when the container carries no build-date label
  if [ -z "$build_date" ]; then
    build_date=$(date -r $image +%Y%m%d)
  fi

  local destination="${ARCHIVE_DIR}/$application/$grouping"
  mkdir -p $destination

  if [ $DEBUG == 'true' ]; then
    echo "Archiving $filename (build date: $build_date) to $destination."
  fi

  # Copy, verify and only then remove the source so the image is never lost on error
  cp $image $destination/${name}_${build_date}.sif

  # Read from stdin so md5sum prints the hash only and the comparison stays a single word
  if [ "$(md5sum < $image)" == "$(md5sum < $destination/${name}_${build_date}.sif)" ]; then
    if [ $DEBUG == 'true' ]; then
      echo "Copy complete and validated. Removing $image."
    fi
    rm -f $image
  else
    echo "ERROR! Checksum of archived container $image does not match! Keeping container."
  fi
}

# Cleanup lock file on error
cleanup() {
  return_code=$?
  if [ $return_code != 0 ]; then
    echo "An error was encountered while running the build_container.sh script. Removing lock file..."
  else
    echo "Removing lockfile"
  fi
  if [ -f $LOCKFILE ]; then
    rm -f $LOCKFILE
  fi
  exit $return_code
}

trap cleanup ERR EXIT

# Parameter handling
while [[ $# -gt 0 ]]; do
  case $1 in
    -v|--debug)
      DEBUG="true"
      echo "Debug enabled"
      shift # past argument
      ;;
    --force)
      FORCE_RUN="true"
      shift # past argument
      ;;
    -b|--branch)
      BRANCH="$2"
      shift # past argument
      shift # past value
      ;;
    -c|--config)
      CONFIGFILE="$2"
      shift # past argument
      shift # past value
      ;;
    -d|--data-dir)
      VIBE_PATH="$2"
      shift # past argument
      shift # past value
      ;;
    -f|--full)
      FULL_BUILD="true"
      shift # past argument
      ;;
    -m|--missing)
      BUILD_MISSING="true"
      shift # past argument
      ;;
    -r|--repo)
      REPO_NAME="$2"
      shift # past argument
      shift # past value
      ;;
    -s|--stage)
      STAGE="$2"
      shift # past argument
      shift # past value
      ;;
    -l|--local-repo)
      LOCAL_REPO="$2"
      shift # past argument
      shift # past value
      ;;
    -t|--repo-token)
      REPO_TOKEN="$2"
      shift # past argument
      shift # past value
      ;;
    -u|--repo-user)
      REPO_USER="$2"
      shift # past argument
      shift # past value
      ;;
    -h|--help)
      echo "Usage: build_containers.sh -r/--repo <repo_name> [OPTIONS]"
      echo "Syncs the repo and builds all changes containers"
      echo ""
      echo "Required parameters:"
      echo "-r, --repo            Name of the repo to clone (vibe-*-*)"
      echo ""
      echo ""
      echo "Optional parameters:"
      echo "-b, --branch          Branch of the repository to build (default: 'main' / 'build' for dev)"
      echo "-c, --config          Location of the config file containing variable overwrites"
      echo "-d, --data-dir        Shared data directory where the files will be stored"
      echo "-f, --full            Trigger a full build (builds all containers, not only the changes ones)"
      echo "-m, --missing         Also build containers that have a definition in the repository but no image yet"
      echo "-s, --stage           Environment to build for, e.g. vibe-desktop-gw (default: derived from the repo name)."
      echo "                      Custom stages behave like development (no archiving) and use their own clone"
      echo "                      <data-dir>/repos/vibe-applications<suffix> of the given repo."
      echo "-l, --local-repo      Existing checkout to build from instead of cloning / pulling (no user or token needed,"
      echo "                      the checked out branch is used unless -b is given). Requires -s or -r."
      echo "                      Only committed changes are detected, use -m or -f for uncommitted ones."
      echo "-t, --repo-token      Token for accessing the repository"
      echo "-u, --repo-user       User name used for accessing the repository"
      echo "-v, --debug           Enables debug messages"
      echo "--force               Force the script to run (ignores lock file)"
      exit 0
      shift # past argument
      ;;
    -*|--*)
      echo "Unknown option $1"
      exit 1
      ;;
    *)
      POSITIONAL_ARGS+=("$1") # save positional arg
      shift # past argument
      ;;
  esac
done

set -- "${POSITIONAL_ARGS[@]}" # restore positional parameters

echo "Starting script $0 at $(date '+%d.%m.%Y %H:%M:%S')."

# Check / compute variables
## Source the config file
if [ ! -z $CONFIGFILE ]; then
  echo "Using the following config file as specified: $CONFIGFILE"

  if [ ! -f $CONFIGFILE ]; then
    echo "ERROR. Config file $CONFIGFILE was specified as parameter but does not exist. Exiting."
    exit 1
  else
    ### Parse the config file
    for line in $(grep -v '^#' $CONFIGFILE | grep -v '^$'); do

      var=$(echo $line | cut -d '=' -f1)

      #### Let values set as parameter overwrite the config file option
      if [ -z ${!var} ]; then

        if [ "$DEBUG" == 'true' ]; then
          if [ $(echo $line | cut -d "=" -f1) == "REPO_TOKEN" ]; then
            ##### Supress output of the token
            echo "Setting the following variable from the config file: REPO_TOKEN=************************ (output hidden)"
          else
            echo "Setting the following variable from the config file: $line"
          fi
        fi

        export "$line"
      fi
    done
  fi

  echo ""

fi

## Set the defaults for unspecified variables
### DEBUG
if [ -z $DEBUG ]; then
  DEBUG='false'
fi
### FULL_BUILD
if [ -z $FULL_BUILD ]; then
  FULL_BUILD='false'
fi
### BUILD_MISSING
if [ -z $BUILD_MISSING ]; then
  BUILD_MISSING='false'
fi
### FORCE_RUN
if [ -z $FORCE_RUN ]; then
  FORCE_RUN='false'
fi
### VIBE_PATH
if [ -z $VIBE_PATH ]; then
  VIBE_PATH=$VIBE_PATH_DEFAULT
fi
### REPO_BASE
if [ -z $REPO_BASE ]; then
  REPO_BASE=$REPO_BASE_DEFAULT
fi

## Existing checkout: use it as is instead of cloning / pulling
if [ -n "$LOCAL_REPO" ]; then
  if ! git -C "$LOCAL_REPO" rev-parse --is-inside-work-tree > /dev/null 2>&1; then
    echo "Error. Local repository $LOCAL_REPO is not a git checkout. Exiting."
    exit 1
  fi
  LOCAL_REPO=$(git -C "$LOCAL_REPO" rev-parse --show-toplevel)
  if [ -z "$REPO_NAME" ] && [ -z "$STAGE" ]; then
    echo "Error. A local repository requires -s/--stage or -r/--repo to determine the stage. Exiting."
    exit 1
  fi
fi
## Remember whether a branch was requested explicitly (a local checkout otherwise keeps its branch)
BRANCH_REQUESTED=${BRANCH}

## Validate required variables are set (not needed for a local checkout: nothing is cloned)
if [ -z "$LOCAL_REPO" ] && [ ${REPO_NAME} != 'vibe-applications' ]; then
  ### Check for Repo User & Token on non-production
  if [ -z ${REPO_USER} ]; then
    echo "Error. No Username for the repo was provided. Exiting."
    exit 1
  fi

  ## Ask / fail is token is missing for non-production repos
  if [ -z ${REPO_TOKEN} ]; then
    if [ $DEBUG == 'true' ]; then
      echo "No REPO_TOKEN parameter provided or present in the config file."
    fi

    ### Abort if running as SLURM script as we can't proceed without token
    if [ $(ps -o comm= $PPID) == "slurmstepd" ]; then
      echo "ERROR! No token provided or REPO_TOKEN set in $CONFIGFILE, but running as SLURM job. Exiting."
      exit 1
    fi

    echo "Please enter the token for user ${REPO_USER}:"
    read -s REPO_TOKEN

    if [ -z ${REPO_TOKEN} ]; then
      echo "Error. No Token was provided. Exiting."
    exit 1
    fi
  fi
fi

## REPO URL
if [ -n "$LOCAL_REPO" ]; then
  REPO_URL=""
elif [ -z ${REPO_NAME} ]; then
  echo "Error! Repo name required but not provided! Exiting."
  exit 1
elif [ ${REPO_NAME} == 'vibe-applications' ]; then
  # We don't need user / token for the public production repo
  REPO_URL=${REPO_BASE}/${REPO_NAME}.git
else
  # Add the user and token to the base url: https://user:token@github.com/dsl-unibe-ch/vibe-applications-dev.git
  REPO_URL=${REPO_BASE/https:\/\//https://$REPO_USER:$REPO_TOKEN@}/${REPO_NAME}.git
fi

## Determine the stage: from -s/--stage if given, otherwise from REPO_NAME
if [ -n "${STAGE}" ]; then
  if [[ ! ${STAGE} =~ ^vibe-desktop(-[A-Za-z0-9_.-]+)?$ ]]; then
    echo "Error. Stage names must be 'vibe-desktop' or start with 'vibe-desktop-' (got '${STAGE}'). Exiting."
    exit 1
  fi
elif [ ${REPO_NAME} == "vibe-applications-dev" ]; then
  STAGE="vibe-desktop-dev"
elif [ ${REPO_NAME} == "vibe-applications-test" ]; then
  STAGE="vibe-desktop-test"
elif [ ${REPO_NAME} == "vibe-applications" ]; then
  STAGE="vibe-desktop"
else
  echo "Error. Could not determine stage from the provided repo name. Exiting."
  exit 1
fi

## Environments reusing the containers of another one (CONTAINER_STAGE in environment.conf) have nothing to build
container_stage=$( [ -f "${VIBE_PATH}/environments/${STAGE}/environment.conf" ] && source "${VIBE_PATH}/environments/${STAGE}/environment.conf"; echo "$CONTAINER_STAGE" )
if [ -n "$container_stage" ] && [ "$container_stage" != "$STAGE" ]; then
  echo "Error. Environment ${STAGE} uses the containers of ${container_stage} (see its environment.conf). Build ${container_stage} instead. Exiting."
  exit 1
fi

## Use lockfile to determine if script is already running
LOCKFILE="${VIBE_PATH}/environments/${STAGE}/.autobuild_running"
if [ $FORCE_RUN == 'false' ]; then

  if [ -f $LOCKFILE ]; then
    echo "ERROR! Build script already running (Lock file $LOCKFILE exists)."
    exit 1
  fi

else

  if [ $DEBUG == 'true' ]; then
    echo "Running script in force mode."

    if [ -f $LOCKFILE ]; then
      echo "Found lock file at $LOCKFILE! Ignoring."
    fi
  fi
fi

## Create the lock file (the environment folder does not exist yet for new environments)
mkdir -p $(dirname $LOCKFILE)
touch $LOCKFILE

## Stage-specific overwrites
### Development: Build from the build branch
if [ $STAGE == 'vibe-desktop-dev' ]; then

  #### Only set BRANCH if it wasn't passed as parameter
  if [ -z $BRANCH ]; then
    BRANCH="build"
  fi
fi

### Build the containers in a separate folder copy when doing a full build and on
### production to allow for release planning
if $FULL_BUILD || [ $STAGE == 'vibe-desktop'  ]; then
  if [ $DEBUG == 'true' ]; then
      echo "Running full build for stage $STAGE."
  fi
  STAGE_DIR="${VIBE_PATH}/environments/${DATE}_${STAGE}"

  #### Create a copy of the existing $STAGE directory. The SLURM wrapper pre-creates $STAGE_DIR/logs, so 'containers' is the marker for an already snapshotted directory
  mkdir -p "${STAGE_DIR}"
  
  if [ -d "${VIBE_PATH}/environments/${STAGE}/" ] && [ ! -d "${STAGE_DIR}/containers" ]; then
    if [ $DEBUG == 'true' ]; then
      echo "Copying existing stage directory to $STAGE_DIR."
    fi
    cp -r "${VIBE_PATH}/environments/${STAGE}/." "${STAGE_DIR}/"
  elif [ $DEBUG == 'true' ]; then
    echo "Not copying the existing stage directory: $STAGE_DIR/containers already exists."
  fi
else
  if [ $DEBUG == 'true' ]; then
      echo "Running normal build for stage $STAGE."
  fi
  STAGE_DIR="${VIBE_PATH}/environments/${STAGE}"
fi

### Default: Build from the main branch
if [ -z ${BRANCH} ]; then
  BRANCH="main"
fi

## Set the destination path for the images based on the STAGE
ARCHIVE_DIR="${VIBE_PATH}/archive/containers"
IMAGE_DIR="${STAGE_DIR}/containers"
LOG_DIR="${STAGE_DIR}/logs"

mkdir -p $ARCHIVE_DIR
mkdir -p $IMAGE_DIR
mkdir -p $LOG_DIR

## Update the REPO_PATH in case the data dir was overwritten via parameter
REPO_PATH=${VIBE_PATH}/repos
## Clone of the applications repo for this stage (vibe-desktop<suffix> -> vibe-applications<suffix>) or the
## given local checkout, also used by the menu builder for the icons. Custom stages get their own clone so
## they never switch the branch of the clones used by the regular stages.
REPO_DIR=${LOCAL_REPO:-${REPO_PATH}/vibe-applications${STAGE#vibe-desktop}}

# Change the umask so the new files keep group writable permissions
umask 0002

# Checkout repo
if [ -n "$LOCAL_REPO" ]; then
  if [ $DEBUG == 'true' ]; then
    echo "Using the existing checkout at ${REPO_DIR} (no clone or pull)."
  fi
  cd ${REPO_DIR}
else
  ## Check if repo path is in git's safe.directory
  if ! git config --global --get-regexp safe.directory ${REPO_DIR}; then
    if [ $DEBUG == 'true' ]; then
      echo "${REPO_DIR} is not yet in git's safe.directory config. Adding it now."
    fi
    git config --global --add safe.directory ${REPO_DIR}
  else
    if [ $DEBUG == 'true' ]; then
      echo "Found ${REPO_DIR} in git's safe.directory config."
    fi
  fi

  ## Clone / Update the repo
  if [ ! -d ${REPO_DIR} ]; then
    if [ $DEBUG == 'true' ]; then
      echo "Directory at ${REPO_PATH} does not exist. Cloning the repository ${REPO_URL} into ${REPO_DIR}."
    fi

    mkdir -p $(dirname ${REPO_PATH})

    git clone ${REPO_URL} ${REPO_DIR}

    cd ${REPO_DIR}

  else
    if [ $DEBUG == 'true' ]; then
      echo "Updating the existing repository clone at ${REPO_DIR}."
    fi
    cd ${REPO_DIR}
    git pull
  fi
fi

## switch to the branch (a local checkout keeps its branch unless one was requested)
if [ -n "$LOCAL_REPO" ] && [ -z "$BRANCH_REQUESTED" ]; then
  BRANCH=$(git rev-parse --abbrev-ref HEAD)
  if [ $DEBUG == 'true' ]; then
    echo "Using the checked out branch $BRANCH"
  fi
else
  if [ $DEBUG == 'true' ]; then
    echo "Using branch $BRANCH"
  fi
  git checkout $BRANCH
fi

# Build images for changed files
## Evaluate changed files (slashes in branch names would create sub folders)
VERSION_FILE=$IMAGE_DIR/.last_build_commit_${BRANCH//\//_}

## Get the repo commit id from the last build for comparison
if [ -f $VERSION_FILE ] && ! $FULL_BUILD; then
  OLD_COMMIT_HASH=$(cat $VERSION_FILE)
else
  ### if the file with the previous commit hash does not exist, use the hash of the initial commit (and build all images)
  OLD_COMMIT_HASH=$(git rev-list --max-parents=0 HEAD)
fi

## Get the commit id of the newest commit from main
NEW_COMMIT_HASH=$(git log -n 1 HEAD | grep "commit" | cut -d ' ' -f2)

if [ $DEBUG == 'true' ]; then
  if $FULL_BUILD; then
    echo "Full build requested. Building all containers up to current commit $NEW_COMMIT_HASH."
  else
    echo "Building all changed container images between last built commit $OLD_COMMIT_HASH and current commit $NEW_COMMIT_HASH."
  fi
  echo ""
fi

## Find all changed files
changed_files=$(git diff --name-only --diff-filter=ACMRT ${OLD_COMMIT_HASH} ${NEW_COMMIT_HASH} -- :^archive */*/** | xargs)
changed_containers=""

## Parse the container name for each changed file
for file in $changed_files; do
  container_name=$(echo $file | cut -d '/' -f1-2)
  changed_containers+=($container_name)
done

## Always add '-latest' containers, but never the retired ones below 'archive'
for file in $(find * -maxdepth 2 -not -path "archive/*" -iwholename "*/*-latest"); do
  changed_containers+=($file)
done

## Add the containers that have a definition in the repository but no image yet
missing_containers=""

if $BUILD_MISSING && ! $FULL_BUILD; then
  ### Only directories holding a build.def are buildable
  for definition in $(find * -mindepth 2 -maxdepth 2 -not -path "archive/*" -name build.def); do
    missing_container=$(dirname $definition)

    if [ ! -f $IMAGE_DIR/$(basename $missing_container).sif ]; then
      if [ $DEBUG == 'true' ]; then
        echo "No image found for $missing_container. Adding it to the build."
      fi
      changed_containers+=($missing_container)
      missing_containers+="$missing_container\n"
    fi
  done
fi

## Get unique container names so we build each container only once
unique_changed_containers=$(printf "%s\n" ${changed_containers[@]} | sort -u)

if [ $DEBUG == 'true' ]; then
  echo "The following files have changes:"
  sed 's/ /\n/g' <<< "$changed_files"
  echo "The following containers will be build:"
  echo $unique_changed_containers
  echo ""
fi

## allow single image builds to fail
set +e
trap ignore_errors ERR

## Iterate over the changed build.def to build and copy the images
for container in $unique_changed_containers; do
  container_name=$(basename $container)
  container_application=$(cut -d '-' -f1 <<< ${container_name})
  container_basename=$(cut -d '-' -f 1-2 <<< ${container_name})
  ### Match the exact version so the other versions in the repository stay in place
  existing_images=$(find $IMAGE_DIR -name "$container_name.sif")
  build_log="${LOG_DIR}/container/$container_application/$container_basename/$(date '+%Y%m%d_%H%M%S')_$container_name.log"

  mkdir -p $(dirname $build_log)

  echo "$(date '+%H:%M:%S'): Processing $container_name..."

  if [ $DEBUG == 'true' ]; then
    echo "Writing build log for $container_name to $build_log."
  fi

  ### Remove old build logs on all stages but production
  if [ ${STAGE} != "vibe-desktop" ]; then
    if [ $DEBUG == 'true' ]; then
      echo "Removing previous log files from $(dirname $build_log)."
    fi
    rm -f $(dirname $build_log)/*.log
  fi
    
  ### Change into the directory of the definition file so the file paths are correct.
  if [ $DEBUG == 'true' ]; then
    echo "Building inside ${REPO_DIR}/$container/."
  fi
  cd ${REPO_DIR}/$container

  ### Build the image using a temporary name
  if [ $DEBUG == 'true' ]; then
    echo "Building definition file $container/build.def to $IMAGE_DIR/.building_$container_name.sif."
  fi
  ### Drop a leftover temporary image of a previously failed build, otherwise apptainer refuses to overwrite it
  rm -f $IMAGE_DIR/.building_$container_name.sif
  apptainer build $IMAGE_DIR/.building_$container_name.sif build.def > $build_log 2>&1

  ### Retry building the container once on failure.
  if [ $? != 0 ]; then
    
    echo ""
    echo "Error building $container. Trying again..."
    echo ""

    echo "-----------------------------------------" >> $build_log
    echo "Error during the build. Retrying..." >> $build_log
    echo "-----------------------------------------" >> $build_log

    apptainer build $IMAGE_DIR/.building_$container_name.sif build.def >> $build_log 2>&1

    #### Log error and continue with the next container if build fails again
    if [ $? != 0 ]; then
      echo "ERROR building $container! Check the log at $build_log for details."
      echo ""
      ERROR_FLAG='true'
      failed_containers+="$container\n"
      rm -f $IMAGE_DIR/.building_$container_name.sif
      continue
    fi
  fi

  ### Production only: archive the previous build of this version before it is replaced
  if [ ${STAGE} == "vibe-desktop" ]; then

    for image in $existing_images; do
      echo "Archiving the previous build of $container_name."
      archive_image $image
    done

  fi

  #### Put the new image in place
  mv $IMAGE_DIR/.building_$container_name.sif $IMAGE_DIR/$container_name.sif

  if [ $DEBUG == 'true' ]; then
    echo "Done building container $container_name."
  fi

  echo ""

done

## Retire the images whose definition was moved to the repository's archive folder
cd ${REPO_DIR}
retired_containers=""

if [ -d archive ]; then
  for definition in $(find archive -mindepth 2 -maxdepth 2 -type d); do
    retired_name=$(basename $definition)
    retired_image=$IMAGE_DIR/$retired_name.sif

    if [ ! -f $retired_image ]; then
      continue
    fi

    echo "$(date '+%H:%M:%S'): Retiring $retired_name, its definition moved to $definition."

    if [ ${STAGE} == "vibe-desktop" ]; then
      archive_image $retired_image
    else
      if [ $DEBUG == 'true' ]; then
        echo "Removing container file $retired_image."
      fi
      rm -f $retired_image
    fi

    retired_containers+="$retired_name\n"
    echo ""
  done
fi

## return to abort script on error
set -e
trap cleanup ERR

## Store new commit hash for the next build
if ! $ERROR_FLAG; then
  if [ $DEBUG == 'true' ]; then
    echo "Done building all images. Writing current commit hash ${NEW_COMMIT_HASH} to $VERSION_FILE."
  fi
  echo ${NEW_COMMIT_HASH} > $VERSION_FILE
fi

# Ensure the menu files and folders are accessible to all users
if [ $DEBUG == 'true' ]; then
  echo "Setting permissions inside $IMAGE_DIR to 775 (directories) / 664 (files)"
fi
find $IMAGE_DIR -type d -exec chmod 0775 {} +
find $IMAGE_DIR -type f -exec chmod 0664 {} +

# Create the container specification file (call the state log script and write the output to file)

# Invoke script to update the menu when containers were built or retired
if [ ! -z "$changed_files" ] || [ ! -z "$missing_containers" ] || [ ! -z "$retired_containers" ]; then
  if [ $DEBUG == 'true' ]; then
    echo "Triggering the rebuild of the menu structure"
  fi
  ## Custom stages may link their scripts/ to a clone that is not named after them, so pass the stage explicitly
  menu_stage_arg=""
  if [ ${STAGE} != "vibe-desktop" ] && [ ${STAGE} != "vibe-desktop-dev" ] && [ ${STAGE} != "vibe-desktop-test" ]; then
    menu_stage_arg="--stage ${STAGE}"
  fi
  if ! VIBE_PATH=${VIBE_PATH} VIBE_APPS_DIR=${REPO_DIR} ${STAGE_DIR}/scripts/menu_builder.sh $menu_stage_arg; then
    echo "Error running the menu builder script! Please update the menu manually."
  fi

  ## Also update the menus of environments showing the containers of this stage (CONTAINER_STAGE in environment.conf)
  for env_conf in ${VIBE_PATH}/environments/*/environment.conf; do
    [ -f "$env_conf" ] || continue
    linked_stage_dir=$(dirname $env_conf)
    if [ "$(source $env_conf; echo $CONTAINER_STAGE)" == "$STAGE" ] && [ "$linked_stage_dir" != "$STAGE_DIR" ]; then
      echo "Updating the menu of $(basename $linked_stage_dir), which uses the containers of $STAGE."
      if ! VIBE_PATH=${VIBE_PATH} VIBE_APPS_DIR=${REPO_DIR} $linked_stage_dir/scripts/menu_builder.sh --stage $(basename $linked_stage_dir); then
        echo "Error running the menu builder script of $(basename $linked_stage_dir)! Please update the menu manually."
      fi
    fi
  done
fi

if $ERROR_FLAG; then
  echo "There was an error when building the containers. The following files failed to be built:"
  echo -e "$failed_containers"
  echo "Please investigate the individual build logs at ${LOG_DIR}."
fi

echo "Finished at $(date '+%d.%m.%Y %H:%M:%S')."