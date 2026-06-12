#!/bin/bash
#------------------------
#SBATCH --account=gratis
#------------------------
#SBATCH --job-name="vibe-desktop-test autobuild"
#SBATCH --time=01:00:00
#SBATCH --mem-per-cpu=2G
#SBATCH --cpus-per-task=32
#SBATCH --mail-type=FAIL,INVALID_DEPEND,STAGE_OUT,TIME_LIMIT,TIME_LIMIT_90
#SBATCH --mail-user=support.vibe@unibe.ch
#SBATCH -o /storage/research/dsl_vibe_rs/environments/vibe-desktop-test/logs/slurm/output_%j.txt
#SBATCH -e /storage/research/dsl_vibe_rs/environments/vibe-desktop-test/logs/slurm/error_%j.txt

# script vars
STAGE="vibe-desktop-test"
VIBE_HOME="/storage/research/dsl_vibe_rs"
CONFIGFILE="$VIBE_HOME/private/buildscripts/configs/config_vibe-desktop-test.conf"
BUILD_SCRIPT="$VIBE_HOME/repos/vibe-utilities/autobuild/build_desktop.sh"
# Weekly time for job resubmit (Format: "next <day> <time>")
RUNDATE="next Mon 01:37:00"
EXIT_CODE=0

# logging vars

# relative path to logging
LOGPATH="environments/$STAGE/logs/build_script/"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

logfile="$VIBE_HOME/$LOGPATH/${TIMESTAMP}_desktop_build.log"

mkdir -p "$VIBE_HOME/$LOGPATH/"

echo "Start building $SLURM_JOB_NAME at $(date +'%Y-%m-%d %H:%M:%S')" > $logfile

$BUILD_SCRIPT --debug -c $CONFIGFILE >> $logfile 2>&1
EXIT_CODE=$?

echo "Done building $SLURM_JOB_NAME at $(date +'%Y-%m-%d %H:%M:%S')" >> $logfile

# Resubmit the job for the next week on dev/test
if [ $STAGE != 'vibe-desktop' ]; then
  echo "" >> $logfile

  # Check if the job is already queued
  ## Get all pending jobs with the same jobname
  queued_starts=$(squeue -n "$SLURM_JOB_NAME" -t PD --json | jq '.jobs[].start_time.number')
  timestamp=$(date -d "$RUNDATE" +'%Y-%m-%dT%H:%M:%S')

  ## Check all queued jobs for matching starting time
  for time in $queued_starts; do
    if [ $(date --date="@$time" +'%Y-%m-%dT%H:%M:%S') == $timestamp ]; then
      already_scheduled='true'
    fi
  done

  ## Submit job only if there is no matching one in the queue
  if [ $already_scheduled ]; then
    echo "Job \"$SLURM_JOB_NAME\" already scheduled to next run at $(date --date=\"@$timestamp\"). Not submitting it again."
  else
    echo "Resubmitting the job to SLURM for next Monday ($timestamp)." >> $logfile
    sbatch --begin="$timestamp" $(scontrol --json show jobid $SLURM_JOB_ID | jq -r '.jobs[].command')
  fi
fi

exit $EXIT_CODE
