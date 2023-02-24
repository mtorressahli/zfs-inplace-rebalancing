#!/usr/bin/env bash

# Exit script on error
set -e

# Exit on undeclared variable
set -u

# File used to track processed files
rebalance_db_file_name="rebalance_db.txt"

# Index used for progress
current_index=0

# Color constants
Color_Off='\033[0m'       # Text Reset
Red='\033[0;31m'          # Red
Green='\033[0;32m'        # Green
Yellow='\033[0;33m'       # Yellow
Cyan='\033[0;36m'         # Cyan

# Global variables
tmp_extension=".balance"

# Functions

# Print a help message
function print_usage() {
    echo "Usage: zfs-inplace-rebalancing --checksum true --passes 1 /my/pool"
}

# Print a given text entirely in a given color
function color_echo() {
    local color=$1
    local text=$2
    echo -e "${color}${text}${Color_Off}"
}

# Get the current rebalance count for a given file
function get_rebalance_count() {
    local file_path=$1

    line_nr=$(grep -xF -n "${file_path}" "./${rebalance_db_file_name}" \
        | head -n 1 | cut -d: -f1)

    if [ -z "${line_nr}" ]; then
        echo "0"
        return
    else
        rebalance_count_line_nr="$((line_nr + 1))"
        rebalance_count=$(awk "NR == ${rebalance_count_line_nr}" "./${rebalance_db_file_name}")
        echo "${rebalance_count}"
        return
    fi
}

# Calculate and print the percentage of files already rebalanced
function update_progress() {
    local current_index="$1"
    local file_count="$2"
    local progress_percent=$(awk "BEGIN {printf \"%.2f\", \
        ${current_index}*100/${file_count}}")
    color_echo "${Cyan}" "Progress -- Files: ${current_index}/${file_count} \
        (${progress_percent}%)"
}

# Check if the target rebalance count is reached for a given file
function check_rebalance_count() {
    local file_path="$1"

    if [ "${passes_flag}" -ge 1 ]; then
        rebalance_count=$(get_rebalance_count "${file_path}")

        if [ "${rebalance_count}" -ge "${passes_flag}" ]; then
            color_echo "${Yellow}" "Rebalance count (${passes_flag}) reached, \
                skipping: ${file_path}"
            return 1
        fi
    fi

    return 0
}

# Copy a file with the appropriate options for the operating system
function copy_file() {
    local file_path=$1
    local tmp_file_path="${file_path}${tmp_extension}"

    echo "Copying '${file_path}' to '${tmp_file_path}'..."

    if [[ "${OSTYPE,,}" == "linux-gnu"* ]]; then
        # Linux
        cp -adxp "${file_path}" "${tmp_file_path}" \
            # -a: keep attributes, -d: keep symlinks, -x: stay on one system, -p: preserve ACLs too
    elif [[ "${OSTYPE,,}" == "darwin"* ]] || [[ "${OSTYPE,,}" == "freebsd"* ]]; then
        # Mac OS, FreeBSD
        cp -axp "${file_path}" "${tmp_file_path}" \
            # -a: Archive mode. Same as -RpP, -x: file system mount points are not traversed, -p: preserve file attributes
    else
        echo "Unsupported OS type: $OSTYPE"
        exit 1
    fi
}

# Compare the original and copy of the file to ensure consistency
function compare_files() {
    local file_path=$1
    local tmp_file_path="${file_path}${tmp_extension}"

    # Check if the checksum flag is set to true
    if [[ "${checksum_flag,,}" == "true"* ]]; then
        echo "Comparing original and copy..."

        # Check the operating system type
        if [[ "${OSTYPE,,}" == "linux-gnu"* ]]; then
            # Linux
            # Generate the MD5 checksum for the original file
            original_md5=$(lsattr "${file_path}" | awk '{print $1}')
            original_md5="${original_md5} $(ls -lha "${file_path}" | awk '{print $1 " " $3 " " $4}')"
            original_md5="${original_md5} $(md5sum -b "${file_path}" | awk '{print $1}')"

            # Generate the MD5 checksum for the copy
            copy_md5=$(lsattr "${tmp_file_path}" | awk '{print $1}')
            copy_md5="${copy_md5} $(ls -lha "${tmp_file_path}" | awk '{print $1 " " $3 " " $4}')"
            copy_md5="${copy_md5} $(md5sum -b "${tmp_file_path}" | awk '{print $1}')"
        elif [[ "${OSTYPE,,}" == "darwin"* ]] || [[ "${OSTYPE,,}" == "freebsd"* ]]; then
            # Mac OS
            # FreeBSD
            # Generate the MD5 checksum for the original file
            original_md5=$(lsattr "${file_path}" | awk '{print $1}')
            original_md5="${original_md5} $(ls -lha "${file_path}" | awk '{print $1 " " $3 " " $4}')"
            original_md5="${original_md5} $(md5 -q "${file_path}")"

            # Generate the MD5 checksum for the copy
            copy_md5=$(lsattr "${tmp_file_path}" | awk '{print $1}')
            copy_md5="${copy_md5} $(ls -lha "${tmp_file_path}" | awk '{print $1 " " $3 " " $4}')"
            copy_md5="${copy_md5} $(md5 -q "${tmp_file_path}")"
        else
            echo "Unsupported OS type: $OSTYPE"
            exit 1
        fi

        # Compare the generated MD5 checksums
        if [[ "${original_md5}" == "${copy_md5}"* ]]; then
            color_echo "${Green}" "MD5 OK"
        else
            color_echo "${Red}" "MD5 FAILED: ${original_md5} != ${copy_md5}"
            exit 1
        fi
    fi
}

# Move the copied file to the original file's location
function move_file() {
    local file_path=$1
    local tmp_file_path="${file_path}${tmp_extension}"

    echo "Removing original '${file_path}'..."
    rm "${file_path}"

    echo "Renaming temporary copy to original '${file_path}'..."
    mv "${tmp_file_path}" "${file_path}"
}

# Update the rebalance count for the file
function update_rebalance_count() {
    local file_path="$1"
    local rebalance_db_file="./${rebalance_db_file_name}"

    if [ "${passes_flag}" -ge 1 ]; then
        # Update the rebalance "database" file
        line_nr=$(grep -xF -n "${file_path}" "${rebalance_db_file}" | head -n 1 | cut -d: -f1)
        if [ -z "${line_nr}" ]; then
            # If this is the first time the file is being rebalanced, add it to the database
            rebalance_count=1
            echo "${file_path}" >> "${rebalance_db_file}"
            echo "${rebalance_count}" >> "${rebalance_db_file}"
        else
            # Otherwise, increment the rebalance count for the file in the database
            rebalance_count_line_nr="$((line_nr + 1))"
            rebalance_count="$((rebalance_count + 1))"
            sed -i "${rebalance_count_line_nr}s/.*/${rebalance_count}/" "${rebalance_db_file}"
        fi
    fi
}


# Rebalance the given file
function rebalance() {
    local file_path="$1"

    # Update progress
    current_index="$((current_index + 1))"
    update_progress "${current_index}" "${file_count}"

    # Check if file exists
    if ! test -f "${file_path}"; then
        color_echo "${Yellow}" "File is missing, skipping: ${file_path}"
        return
    fi

    # Check if rebalance count is reached
    if ! check_rebalance_count "${file_path}"; then
        return
    fi

    # Copy the file to a temporary location
    copy_file "${file_path}"

    # Compare the original and copied file to ensure consistency
    compare_files "${file_path}"

    # Move the copied file to the original location
    move_file "${file_path}"

    # Update the rebalance count for the file
    update_rebalance_count "${file_path}"
}

# Set the checksum and passes flags based on command-line arguments
checksum_flag='true'
passes_flag='1'
if [ "$#" -eq 0 ]; then
    print_usage
    exit 0
fi
while true ; do
    case "$1" in
        -c | --checksum )
            if [[ "$2" == 1 || "$2" =~ (on|true|yes) ]]; then
                checksum_flag="true"
            else
                checksum_flag="false"
            fi
            shift 2
        ;;
        -p | --passes )
            passes_flag=$2
            shift 2
        ;;
        *)
            break
        ;;
    esac 
done;

root_path=$1

# Print rebalancing parameters
color_echo "$Cyan" "Start rebalancing:"
color_echo "$Cyan" "  Path: ${root_path}"
color_echo "$Cyan" "  Rebalancing Passes: ${passes_flag}"
color_echo "$Cyan" "  Use Checksum: ${checksum_flag}"

# Count files
file_count=$(find "${root_path}" -type f | wc -l)
color_echo "$Cyan" "  File count: ${file_count}"

# Create rebalance database file if needed
if [ "${passes_flag}" -ge 1 ]; then
    touch "./${rebalance_db_file_name}"
fi

# Recursively scan through files and execute the "rebalance" procedure
find "$root_path" -type f -print0 | while IFS= read -r -d '' file; do rebalance "$file"; done

echo ""
echo ""
color_echo "$Green" "Done!"
