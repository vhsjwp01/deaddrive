#!/bin/bash
#set -x

################################################################################
#                      S C R I P T    D E F I N I T I O N
################################################################################
#

#-------------------------------------------------------------------------------
# Revision History
#-------------------------------------------------------------------------------
# 20141020     Jason W. Plummer          Original: A simple script to scrape
#                                        zpool status output for unavailable
#                                        drives and then activate their status
#                                        LED using ledctl.  Loops through LED
#                                        status one drive at a time
# 20141021     Jason W. Plummer          Modified to set all problem drive LEDS
#                                        at once
# 20141022     Jason W. Plummer          Added logging capability
# 20141023     Jason W. Plummer          Modified to fit this documentation
#                                        format.  Checks that invoking user is 
#                                        id=0

################################################################################
# DESCRIPTION
################################################################################
#

# Name: deaddrive.sh

# This script executes the following cycle:
#
# 1. Look for zfs problem disks in online but degraded storage pools
#    NOTE: Identified by "state: DEGRADED" in the 'zpool status <pool>' output
# 2. If no problems, clear existing alerts (goto 5)
# 3. If problems, create problem list
# 4. Loop through problem disk LEDs for a defined cycle
# 5. Sleep cycle (goto 1)

# NOTE: Intended to run as an inittab or upstart jobd

# Usage: /usr/local/bin/deaddrive.sh

################################################################################
# CONSTANTS
################################################################################
#

TERM=vt100
PATH=/bin:/usr/bin:/usr/local/bin:/sbin:/usr/sbin:/usr/local/sbin
export TERM PATH

SUCCESS=0
ERROR=1

LOG_DIR=/var/log/zfs
LOG_FILE=dead_drive.log
ALARM_FLAG="dead_drive.alarm"

################################################################################
# VARIABLES
################################################################################
#

err_msg=""
exit_code=${SUCCESS}

blank_target="/dev/NON-EXISTENT_TARGET"
sleep_interval=300
flash_interval=10
flash_sleep=5
alarm_cycles=10

################################################################################
# SUBROUTINES
################################################################################
#

# WHAT: Subroutine f__check_command
# WHY:  This subroutine checks the contents of lexically scoped ${1} and then
#       searches ${PATH} for the command.  If found, a variable of the form
#       my_${1} is created.
# NOTE: Lexically scoped ${1} should not be null, otherwise the command for
#       which we are searching is not present via the defined ${PATH} and we
#       should complain
#
f__check_command() {
    return_code=${SUCCESS}
    my_command="${1}"

    if [ "${my_command}" != "" ]; then
        my_command_check=`unalias "${i}" ; which "${1}" 2> /dev/null`

        if [ "${my_command_check}" = "" ]; then
            return_code=${ERROR}
        else
            eval my_${my_command}="${my_command_check}"
        fi

    else
        err_msg="No command was specified"
        return_code=${ERROR}
    fi

    return ${return_code}
}

#-------------------------------------------------------------------------------

################################################################################
# MAIN
################################################################################
#

# WHAT: Make sure we have some useful commands
# WHY:  Cannot proceed otherwise
#
if [ ${exit_code} -eq ${SUCCESS} ]; then

    for command in awk date id ledctl ls mkdir sleep tr rm zpool ; do
        unalias ${command} > /dev/null 2>&1
        f__check_command "${command}"

        if [ ${?} -ne ${SUCCESS} ]; then
            let exit_code=${exit_code}+1
        fi

    done

fi

# WHAT: Make sure we are root
# WHY:  Cannot proceed otherwise
#
if [ ${exit_code} -eq ${SUCCESS} ]; then
    this_uid=`${my_id} -u 2> /dev/null`

    if [ "${this_uid}" != "0" ]; then
        err_msg="You must be root to run this script"
        exit_code=${ERROR}
    fi

fi

# WHAT: Make sure we have a ${LOG_DIR}
# WHY:  Needed later
#
if [ ${exit_code} -eq ${SUCCESS} ]; then

    if [ ! -d "${LOG_DIR}" ]; then
        ${my_mkdir} -p "${LOG_DIR}" > /dev/null 2>&1
        exit_code=${?}

        if [ ${exit_code} -ne ${SUCCESS} ]; then
            err_msg="Could not create directory \"${LOG_DIR}\""
        fi

    fi

fi

# WHAT: Make sre we have some zfs pools to monitor
# WHY:  Can't continue otherwise
#
if [ ${exit_code} -eq ${SUCCESS} ]; then
    my_zpools=`${my_zpool} status 2>&1 | ${my_awk} '/pool:/ {print $NF}'`

    if [ "${my_zpools}" = "" ]; then
        err_msg="No ZFS data pools present"
        exit_code=${ERROR}
    fi

fi

# WHAT: Start the monitor loop
# WHY:  The reason we are here
#
while [ ${exit_code} -eq ${SUCCESS} ]; do
    echo "`${my_date}`: INFO - Beginning ZFS pool search for problem drives" >> "${LOG_DIR}/${LOG_FILE}"
    csv_list=""

    for zpool in ${my_zpools} ; do
        state=`${my_zpool} status "${zpool}" 2>&1 | ${my_awk} '/state:/ {print $NF}' | ${my_tr} '[A-Z]' '[a-z]'`
        problem_drives=`${my_zpool} status "${zpool}" 2>&1 | ${my_awk} '/UNAVAIL/ {print $1}'`

        for real_drive in ${problem_drives}; do
            is_disk_id=`${my_ls} /dev/disk/by-id/${real_drive} 2> /dev/null`
            is_disk_uuid=`${my_ls} /dev/disk/by-uuid/${real_drive} 2> /dev/null`
            is_disk_path=`${my_ls} /dev/disk/by-path/${real_drive} 2> /dev/null`
            is_disk_dev=`${my_ls} /dev/${real_drive} 2> /dev/null`

            if [ "${is_disk_id}" != "" ]; then
                this_target="${is_disk_id}"
            elif [ "${is_disk_uuid}" != "" ]; then
                this_target="${is_disk_uuid}"
            elif [ "${is_disk_path}" != "" ]; then
                this_target="${is_disk_path}"
            elif [ "${is_disk_dev}" != "" ]; then
                this_target="${is_disk_dev}"
            else
                this_target=""
            fi

            if [ "${this_target}" != "" ]; then

                if [ "${csv_list}" = "" ]; then
                    csv_list="${this_target}"
                else
                    csv_list="${csv_list},${this_target}"
                fi

            fi

        done

        case ${state} in 

            online|offline)

                # Clear all alarms
                if [ -e "${LOG_DIR}/${ALARM_FLAG}" ]; then
                    ${my_rm} -f "${LOG_DIR}/${ALARM_FLAG}" > /dev/null 2>&1
                    echo "`${my_date}`:   INFO - ALL CLEAR - Clearing all drive LED alarms" >> "${LOG_DIR}/${LOG_FILE}"
                    ${my_ledctl} locate="${blank_target}" > /dev/null 2>&1
                fi

            ;;

            degraded|unavail)

                # Find the dead drives
                if [ "${csv_list}" != "" ]; then

                    # Create alarm flag
                    echo "`${my_date}`:   ${csv_list}" > "${LOG_DIR}/${ALARM_FLAG}"
                    echo "`${my_date}`:   ALARM - Discovered problems with the following drive(s): ${csv_list}" >> "${LOG_DIR}/${LOG_FILE}"
                fi

            ;;

        esac

    done

    # If we have items in the "${csv_list}" list, then flash each drive LED for ${flash_interval} seconds
    # Do this for ${alarm_cycles} cycles
    #
    if [ "${csv_list}" != "" ]; then
        let counter=${alarm_cycles}

        while [ ${counter} -gt 0 ]; do
            let this_cycle=${alarm_cycles}-${counter}+1
            let counter=${counter}-1

            # Turn any alarm LEDs off - Creates a strobe effect to attract attention
            ${my_ledctl} locate_off="${csv_list}" > /dev/null 2>&1
            ${my_sleep} ${flash_sleep}

            # Turn any alarm LEDs on - this is done last on purpose so that 
            #                          the status LEDs will continue to flash
            #                          during the sleep period
            echo "`${my_date}`:   ALARM CYCLE ${this_cycle} - Activating drive status LED for: ${csv_list}" >> "${LOG_DIR}/${LOG_FILE}"
            ${my_ledctl} locate="${csv_list}" > /dev/null 2>&1
            ${my_sleep} ${flash_interval}
        done

    fi

    echo "`${my_date}`: INFO - Sleeping for ${sleep_interval} seconds" >> "${LOG_DIR}/${LOG_FILE}"
    ${my_sleep} ${sleep_interval}
done

# WHAT: Complain if necessary then exit
# WHY:  Success or failure, either way we are through
#
if [ ${exit_code} -ne ${SUCCESS} ]; then

    if [ "${err_msg}" != "" ]; then
        echo 
        echo "    ERROR:  ${err_msg} ... processing halted" 
        echo 
    fi

fi

exit ${exit_code}
