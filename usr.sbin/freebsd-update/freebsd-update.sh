#!/bin/sh

#-
# SPDX-License-Identifier: BSD-2-Clause-FreeBSD
#
# Copyright 2004-2007 Colin Percival
# All rights reserved
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted providing that the following conditions 
# are met:
# 1. Redistributions of source code must retain the above copyright
#    notice, this list of conditions and the following disclaimer.
# 2. Redistributions in binary form must reproduce the above copyright
#    notice, this list of conditions and the following disclaimer in the
#    documentation and/or other materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR
# IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
# WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
# ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY
# DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
# DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
# OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
# HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
# STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING
# IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
# POSSIBILITY OF SUCH DAMAGE.

# $FreeBSD$

#### Usage function -- called from command-line handling code.

# Usage instructions.  Options not listed:
# --debug	-- don't filter output from utilities
# --no-stats	-- don't show progress statistics while fetching files

export EX_TEMPFAIL=75
export SPLAY_SECONDS=3600

usage () {
	cat <<EOF
usage: `basename $0` [options] command ...

Options:
  -b basedir   -- Operate on a system mounted at basedir
                  (default: /)
  -d workdir   -- Store working files in workdir
                  (default: /var/db/freebsd-update/)
  -f conffile  -- Read configuration options from conffile
                  (default: /etc/freebsd-update.conf)
  -F           -- Force a fetch operation to proceed in the
                  case of an unfinished upgrade
  -j jail      -- Operate on the given jail specified by jid or name
  -k KEY       -- Trust an RSA key with SHA256 hash of KEY
  -r release   -- Target for upgrade (e.g., 11.1-RELEASE)
  -s server    -- Server from which to fetch updates
                  (default: update.FreeBSD.org)
  -t address   -- Mail output of cron command, if any, to address
                  (default: root)
  --not-running-from-cron
               -- Run without a tty, for use by automated tools
  --currently-running release
               -- Update as if currently running this release
Commands:
  fetch        -- Fetch updates from server
  cron         -- Sleep rand(3600) seconds, fetch updates, and send an
                  email if updates were found
  upgrade      -- Fetch upgrades to FreeBSD version specified via -r option
  updatesready -- Check if there are fetched updates ready to install
  install      -- Install downloaded updates or upgrades
  rollback     -- Uninstall most recently installed updates
  IDS          -- Compare the system against an index of "known good" files
  showconfig   -- Show configuration
EOF
	exit 0
}

#### Configuration processing functions

#-
# Configuration options are set in the following order of priority:
# 1. Command line options
# 2. Configuration file options
# 3. Default options
# In addition, certain options (e.g., IgnorePaths) can be specified multiple
# times and (as long as these are all in the same place, e.g., inside the
# configuration file) they will accumulate.  Finally, because the path to the
# configuration file can be specified at the command line, the entire command
# line must be processed before we start reading the configuration file.
#
# Sound like a mess?  It is.  Here's how we handle this:
# 1. Initialize CONFFILE and all the options to "".
# 2. Process the command line.  Throw an error if a non-accumulating option
#    is specified twice.
# 3. If CONFFILE is "", set CONFFILE to /etc/freebsd-update.conf .
# 4. For all the configuration options X, set X_saved to X.
# 5. Initialize all the options to "".
# 6. Read CONFFILE line by line, parsing options.
# 7. For each configuration option X, set X to X_saved iff X_saved is not "".
# 8. Repeat steps 4-7, except setting options to their default values at (6).

export CONFIGOPTIONS="KEYPRINT WORKDIR SERVERNAME MAILTO ALLOWADD ALLOWDELETE
    KEEPMODIFIEDMETADATA COMPONENTS IGNOREPATHS UPDATEIFUNMODIFIED
    BASEDIR VERBOSELEVEL TARGETRELEASE STRICTCOMPONENTS MERGECHANGES
    IDSIGNOREPATHS BACKUPKERNEL BACKUPKERNELDIR BACKUPKERNELSYMBOLFILES"

# Set all the configuration options to "".
nullconfig () {
	for X in ${CONFIGOPTIONS}; do
		eval ${X}=""
	done
}

# For each configuration option X, set X_saved to X.
saveconfig () {
	for X in ${CONFIGOPTIONS}; do
		eval ${X}_saved=\$${X}
	done
}

# For each configuration option X, set X to X_saved if X_saved is not "".
mergeconfig () {
	for X in ${CONFIGOPTIONS}; do
		eval _=\$${X}_saved
		if ! [ -z "${_}" ]; then
			eval ${X}=\$${X}_saved
		fi
	done
}

# Set the trusted keyprint.
config_KeyPrint () {
	if [ -z ${KEYPRINT} ]; then
		export KEYPRINT=$1
	else
		return 1
	fi
}

# Set the working directory.
config_WorkDir () {
	if [ -z ${WORKDIR} ]; then
		export WORKDIR=$1
	else
		return 1
	fi
}

# Set the name of the server (pool) from which to fetch updates
config_ServerName () {
	if [ -z ${SERVERNAME} ]; then
		export SERVERNAME=$1
	else
		return 1
	fi
}

# Set the address to which 'cron' output will be mailed.
config_MailTo () {
	if [ -z ${MAILTO} ]; then
		export MAILTO=$1
	else
		return 1
	fi
}

# Set whether FreeBSD Update is allowed to add files (or directories, or
# symlinks) which did not previously exist.
config_AllowAdd () {
	if [ -z ${ALLOWADD} ]; then
		case $1 in
		[Yy][Ee][Ss])
			export ALLOWADD=yes
			;;
		[Nn][Oo])
			export ALLOWADD=no
			;;
		*)
			return 1
			;;
		esac
	else
		return 1
	fi
}

# Set whether FreeBSD Update is allowed to remove files/directories/symlinks.
config_AllowDelete () {
	if [ -z ${ALLOWDELETE} ]; then
		case $1 in
		[Yy][Ee][Ss])
			export ALLOWDELETE=yes
			;;
		[Nn][Oo])
			export ALLOWDELETE=no
			;;
		*)
			return 1
			;;
		esac
	else
		return 1
	fi
}

# Set whether FreeBSD Update should keep existing inode ownership,
# permissions, and flags, in the event that they have been modified locally
# after the release.
config_KeepModifiedMetadata () {
	if [ -z ${KEEPMODIFIEDMETADATA} ]; then
		case $1 in
		[Yy][Ee][Ss])
			export KEEPMODIFIEDMETADATA=yes
			;;
		[Nn][Oo])
			export KEEPMODIFIEDMETADATA=no
			;;
		*)
			return 1
			;;
		esac
	else
		return 1
	fi
}

# Add to the list of components which should be kept updated.
config_Components () {
	for C in $@; do
		export COMPONENTS="${COMPONENTS} ${C}"
	done
}

# Add to the list of paths under which updates will be ignored.
config_IgnorePaths () {
	for C in $@; do
		export IGNOREPATHS="${IGNOREPATHS} ${C}"
	done
}

# Add to the list of paths which IDS should ignore.
config_IDSIgnorePaths () {
	for C in $@; do
		export IDSIGNOREPATHS="${IDSIGNOREPATHS} ${C}"
	done
}

# Add to the list of paths within which updates will be performed only if the
# file on disk has not been modified locally.
config_UpdateIfUnmodified () {
	for C in $@; do
		export UPDATEIFUNMODIFIED="${UPDATEIFUNMODIFIED} ${C}"
	done
}

# Add to the list of paths within which updates to text files will be merged
# instead of overwritten.
config_MergeChanges () {
	for C in $@; do
		export MERGECHANGES="${MERGECHANGES} ${C}"
	done
}

# Work on a FreeBSD installation mounted under $1
config_BaseDir () {
	if [ -z ${BASEDIR} ]; then
		export BASEDIR=$1
	else
		return 1
	fi
}

# When fetching upgrades, should we assume the user wants exactly the
# components listed in COMPONENTS, rather than trying to guess based on
# what's currently installed?
config_StrictComponents () {
	if [ -z ${STRICTCOMPONENTS} ]; then
		case $1 in
		[Yy][Ee][Ss])
			export STRICTCOMPONENTS=yes
			;;
		[Nn][Oo])
			export STRICTCOMPONENTS=no
			;;
		*)
			return 1
			;;
		esac
	else
		return 1
	fi
}

# Upgrade to FreeBSD $1
config_TargetRelease () {
	if [ -z ${TARGETRELEASE} ]; then
		export TARGETRELEASE=$1
	else
		return 1
	fi
	if echo ${TARGETRELEASE} | grep -qE '^[0-9.]+$'; then
		export TARGETRELEASE="${TARGETRELEASE}-RELEASE"
	fi
}

# Pretend current release is FreeBSD $1
config_SourceRelease () {
	UNAME_r=$1
	if echo ${UNAME_r} | grep -qE '^[0-9.]+$'; then
		UNAME_r="${UNAME_r}-RELEASE"
	fi
	export UNAME_r
}

# Get the Jail's path and the version of its installed userland
config_TargetJail () {
	JAIL=$1
	UNAME_r=$(freebsd-version -j ${JAIL})
	export BASEDIR=$(jls -j ${JAIL} -h path | awk 'NR == 2 {print}')
	if [ -z ${BASEDIR} ] || [ -z ${UNAME_r} ]; then
		echo "The specified jail either doesn't exist or" \
		      "does not have freebsd-version."
		exit 1
	fi
	export UNAME_r
}

# Define what happens to output of utilities
config_VerboseLevel () {
	if [ -z ${VERBOSELEVEL} ]; then
		case $1 in
		[Dd][Ee][Bb][Uu][Gg])
			export VERBOSELEVEL=debug
			;;
		[Nn][Oo][Ss][Tt][Aa][Tt][Ss])
			export VERBOSELEVEL=nostats
			;;
		[Ss][Tt][Aa][Tt][Ss])
			export VERBOSELEVEL=stats
			;;
		*)
			return 1
			;;
		esac
	else
		return 1
	fi
}

config_BackupKernel () {
	if [ -z ${BACKUPKERNEL} ]; then
		case $1 in
		[Yy][Ee][Ss])
			export BACKUPKERNEL=yes
			;;
		[Nn][Oo])
			export BACKUPKERNEL=no
			;;
		*)
			return 1
			;;
		esac
	else
		return 1
	fi
}

config_BackupKernelDir () {
	if [ -z ${BACKUPKERNELDIR} ]; then
		if [ -z "$1" ]; then
			echo "BackupKernelDir set to empty dir"
			return 1
		fi

		# We check for some paths which would be extremely odd
		# to use, but which could cause a lot of problems if
		# used.
		case $1 in
		/|/bin|/boot|/etc|/lib|/libexec|/sbin|/usr|/var)
			echo "BackupKernelDir set to invalid path $1"
			return 1
			;;
		/*)
			export BACKUPKERNELDIR=$1
			;;
		*)
			echo "BackupKernelDir ($1) is not an absolute path"
			return 1
			;;
		esac
	else
		return 1
	fi
}

config_BackupKernelSymbolFiles () {
	if [ -z ${BACKUPKERNELSYMBOLFILES} ]; then
		case $1 in
		[Yy][Ee][Ss])
			export BACKUPKERNELSYMBOLFILES=yes
			;;
		[Nn][Oo])
			export BACKUPKERNELSYMBOLFILES=no
			;;
		*)
			return 1
			;;
		esac
	else
		return 1
	fi
}

config_CreateBootEnv () {
	if [ -z ${BOOTENV} ]; then
		case $1 in
		[Yy][Ee][Ss])
			export BOOTENV=yes
			;;
		[Nn][Oo])
			export BOOTENV=no
			;;
		*)
			return 1
			;;
		esac
	else
		return 1
	fi
}

# Handle one line of configuration
configline () {
	if [ $# -eq 0 ]; then
		return
	fi

	OPT=$1
	shift
	config_${OPT} $@
}

#### Parameter handling functions.

# Initialize parameters to null, just in case they're
# set in the environment.
init_params () {
	# Configration settings
	nullconfig

	# No configuration file set yet
	CONFFILE=""

	# No commands specified yet
	export COMMANDS=""

	# Force fetch to proceed
	export FORCEFETCH=0

	# Run without a TTY
	export NOTTYOK=0

	# Fetched first in a chain of commands
	export ISFETCHED=0
}

# Parse the command line
parse_cmdline () {
	while [ $# -gt 0 ]; do
		case "$1" in
		# Location of configuration file
		-f)
			if [ $# -eq 1 ]; then usage; fi
			if [ ! -z "${CONFFILE}" ]; then usage; fi
			shift; CONFFILE="$1"
			;;
		-F)
			FORCEFETCH=1
			;;
		--not-running-from-cron)
			NOTTYOK=1
			;;
		--currently-running)
			shift
			config_SourceRelease $1 || usage
			;;

		# Configuration file equivalents
		-b)
			if [ $# -eq 1 ]; then usage; fi; shift
			config_BaseDir $1 || usage
			;;
		-d)
			if [ $# -eq 1 ]; then usage; fi; shift
			config_WorkDir $1 || usage
			;;
		-j)
			if [ $# -eq 1 ]; then usage; fi; shift
			config_TargetJail $1 || usage
			;;
		-k)
			if [ $# -eq 1 ]; then usage; fi; shift
			config_KeyPrint $1 || usage
			;;
		-s)
			if [ $# -eq 1 ]; then usage; fi; shift
			config_ServerName $1 || usage
			;;
		-r)
			if [ $# -eq 1 ]; then usage; fi; shift
			config_TargetRelease $1 || usage
			;;
		-t)
			if [ $# -eq 1 ]; then usage; fi; shift
			config_MailTo $1 || usage
			;;
		-v)
			if [ $# -eq 1 ]; then usage; fi; shift
			config_VerboseLevel $1 || usage
			;;

		# Aliases for "-v debug" and "-v nostats"
		--debug)
			config_VerboseLevel debug || usage
			;;
		--no-stats)
			config_VerboseLevel nostats || usage
			;;

		# Commands
		cron | fetch | upgrade | updatesready | install | rollback |\
		IDS | showconfig)
			COMMANDS="${COMMANDS} $1"
			;;

		# Anything else is an error
		*)
			usage
			;;
		esac
		shift
	done

	# Make sure we have at least one command
	if [ -z "${COMMANDS}" ]; then
		usage
	fi
}

# Parse the configuration file
parse_conffile () {
	# If a configuration file was specified on the command line, check
	# that it exists and is readable.
	if [ ! -z "${CONFFILE}" ] && [ ! -r "${CONFFILE}" ]; then
		echo -n "File does not exist "
		echo -n "or is not readable: "
		echo ${CONFFILE}
		exit 1
	fi

	# If a configuration file was not specified on the command line,
	# use the default configuration file path.  If that default does
	# not exist, give up looking for any configuration.
	if [ -z "${CONFFILE}" ]; then
		CONFFILE="/etc/freebsd-update.conf"
		if [ ! -r "${CONFFILE}" ]; then
			return
		fi
	fi

	# Save the configuration options specified on the command line, and
	# clear all the options in preparation for reading the config file.
	saveconfig
	nullconfig

	# Read the configuration file.  Anything after the first '#' is
	# ignored, and any blank lines are ignored.
	L=0
	while read LINE; do
		L=$(($L + 1))
		LINEX=`echo "${LINE}" | cut -f 1 -d '#'`
		if ! configline ${LINEX}; then
			echo "Error processing configuration file, line $L:"
			echo "==> ${LINE}"
			exit 1
		fi
	done < ${CONFFILE}

	# Merge the settings read from the configuration file with those
	# provided at the command line.
	mergeconfig
}

# Provide some default parameters
default_params () {
	# Save any parameters already configured, and clear the slate
	saveconfig
	nullconfig

	# Default configurations
	config_WorkDir /var/db/freebsd-update
	config_MailTo root
	config_AllowAdd yes
	config_AllowDelete yes
	config_KeepModifiedMetadata yes
	config_BaseDir /
	config_VerboseLevel stats
	config_StrictComponents no
	config_BackupKernel yes
	config_BackupKernelDir /boot/kernel.old
	config_BackupKernelSymbolFiles no
	config_CreateBootEnv yes

	# Merge these defaults into the earlier-configured settings
	mergeconfig
}

# Using the command line, configuration file, and defaults,
# set all the parameters which are needed later.
get_params () {
	init_params
	parse_cmdline $@
	parse_conffile
	default_params
}

#### Entry point

# Make sure we find utilities from the base system
export PATH=/sbin:/bin:/usr/sbin:/usr/bin:${PATH}

# Set a pager if the user doesn't
if [ -z "$PAGER" ]; then
	PAGER=/usr/bin/less
fi

# Set LC_ALL in order to avoid problems with character ranges like [A-Z].
export LC_ALL=C

get_params $@

# Sleep rand(3600) before attempting to lock locking working directory and
# executing cmd_cron().  This avoids locking the working directory during
# splay time.
for COMMAND in ${COMMANDS}; do
    if [ "$COMMAND" == "cron" ]; then
	    sleep `jot -r 1 0 $SPLAY_SECONDS`
    fi
done

# Lock working directory before executing freebsd-update command functions
# to prevent other instances of freebsd-update from using the same working 
# directory at the same time.
lockf -s -t 0 ${WORKDIR}/lock /bin/sh /usr/libexec/freebsd-update/commands
if [ $? -eq $EX_TEMPFAIL ]; then
    echo "another freebsd-update(8) instance is running in ${WORKDIR}"
    echo "specify a different work directory with -d"
    exit $EX_TEMPFAIL
fi

