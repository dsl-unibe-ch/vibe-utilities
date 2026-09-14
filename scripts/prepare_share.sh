#!/bin/bash
# This script is part of the VIBE Desktop.
# It prepares the folder to be usable by the VIBE desktop by creating the folder structure, symlinks and setting
# the required permissions.
# The folder needs be accessible by all users.
#
# This script assumes that the share uses SGID to created new files / folders with the correct group ownership.

SHARE=/storage/research/dsl_vibe_rs

# Stages that are using manual releases (production stages)
RELEASE_STAGES="vibe-desktop"

# Stages that don't use releases (mostly -dev and -test)
STANDALONE_STAGES="vibe-desktop-dev vibe-desktop-test"

# Archive
mkdir -p $SHARE/archive/{containers,desktop}
find /$SHARE/archive/ -type d -exec chmod 0775 '{}' \;

# repos
mkdir -p $SHARE/repos

# environments
mkdir -p $SHARE/environments/

chmod 0775 $SHARE/environments/

cd $SHARE/environments/

## Get all stage folders for releases
stages=""
for stage in $RELEASE_STAGES; do
  if test -L $stage; then
    # Add the target of the symlink
    stages+=($(readlink $stage))
  else
    # Release folder not yet available; create a new one
    release_dir="$(date +'%Y%m%d')_$stage"
    mkdir $release_dir
    ln -s $release_dir $stage
    stages+=($release_dir)
  fi

done

for stage in $STANDALONE_STAGES; do
  stages+=($stage)
done

## sort the listand get unique elements
unique_stages=$(printf "%s\n" ${stages[@]} | sort -u)

## Create the stages folders
for stage in $unique_stages; do

  echo "Processing $stage..."

  stage_folder="$SHARE/environments/$stage"
  mkdir -p $stage_folder/{containers,logs}

  ### desktop folder
  if [ ! -d $stage_folder/desktop/launcher/ ]; then
    echo "Desktop template does not exist. Copying it from the repo..."
    mkdir -p $stage_folder/desktop
    if [ -d $SHARE/repos/vibe-utilities/desktop-templates/ ]; then
      cp -r $SHARE/repos/vibe-utilities/desktop-templates/* $stage_folder/desktop/
    else
      echo "Error! Repository 'vibe-utilities' was not cloned to $SHARE/repos/vibe-utilities/. Clone it and run this script again."
    fi
  fi
  
  ### Set the permissions
  find $stage_folder -type d -exec chmod 0775 '{}' \;
  find $stage_folder -type f -exec chmod 0664 '{}' \;

  echo ""

  ### Create the scripts/ symlink if the repo was cloned locally
  echo "Creating symlink to scripts/ folder in stages' repository..."
  if ! test -d $SHARE/repos/$stage/scripts; then
    echo "Error! Repository for $stage was not yet cloned locally. Skipping scripts/ symlink and permissions."
    echo "Clone the repository to $SHARE/repos/$stage and run this script again."
  else
    ln -s $SHARE/repos/$stage/scripts/ $SHARE/environments/$stage/scripts
    chmod 0775 $SHARE/repos/$stage/scripts/*.sh
  fi

  echo ""

done
