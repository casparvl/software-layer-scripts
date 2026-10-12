# Functions for debugging a bot build interactively, sourced by bot/build.sh if EESSI_INTERACTIVE_BUILD is set.
# See the comments at the top of bot/build.sh for the user-facing description.
#
# Requires fatal_error and echo_yellow (scripts/utils.sh).

# Ask the user to choose a number between $4 (lowest number, default 1) and $2 (highest number) for $1 (description of
# what is chosen), default $3 (default number). The result is returned in CHOSEN_NUMBER.
# Note that all output of the dialog goes to stderr, like the prompt of 'read -p' does (bash's own convention for prompts)
interactive_choice() {
    local description="$1" highest_number="$2" default_number="$3" lowest_number="${4:-1}" answer
    # loop until we get a valid answer
    while true; do
        # Use the default & exit the loop if read returns non-zero, e.g. at EOF because user pressed Ctrl+D / terminal
        # disappears (avoid infinite loop)
        if ! read -r -p "bot/build.sh: select ${description} [${lowest_number}-${highest_number}, default ${default_number}]: " answer; then
            echo >&2
            CHOSEN_NUMBER=${default_number}
            return
        fi
        answer=${answer:-${default_number}}
        # Check answer is valid and return
        if [[ "${answer}" =~ ^[0-9]+$ ]] && (( answer >= lowest_number && answer <= highest_number )); then
            CHOSEN_NUMBER=${answer}
            return
        fi
        echo "bot/build.sh: invalid choice '${answer}'" >&2
    done
}

# Print the position (counting from 1) in the array named $1 of the first entry that equals one of the other arguments
# (the search values), or 0 if none does
position_of() {
    local -n array="$1"
    shift
    local i search_value
    for i in "${!array[@]}"; do
        for search_value in "$@"; do
            if [[ "${array[$i]}" == "${search_value}" ]]; then
                echo $((i+1))
                return
            fi
        done
    done
    echo 0
}

# Choose one entry of the array named $5, and return its number in CHOSEN_NUMBER: N for entry N of the array (counting from
# 1), and 0 for 'none' (only allowed if $4, the lowest number, is 0).
#   $1 description of what is chosen, $2 name of the environment variable with which the user can set it, $3 default
#   number, $4 lowest number
# If there is only one option, we don't need to choose. Otherwise we ask the user, if stdin is a terminal, or else use the
# default and warn
choose_option() {
    local description="$1" env_var_name="$2" default_number="$3" lowest_number="$4"
    local -n option_array="$5"
    local highest_number=${#option_array[@]}
    if [[ ${highest_number} -eq ${lowest_number} ]]; then
        CHOSEN_NUMBER=${highest_number}
    elif [[ -t 0 ]]; then
        interactive_choice "${description}" ${highest_number} ${default_number} ${lowest_number}
    else
        CHOSEN_NUMBER=${default_number}
        local assumed_description="none"
        [[ ${CHOSEN_NUMBER} -gt 0 ]] && assumed_description="'${option_array[$((CHOSEN_NUMBER-1))]}'"
        echo_yellow "bot/build.sh: WARNING: stdin is not a terminal, so could not ask which ${description}. Assuming ${assumed_description}. To choose explicitly, set ${env_var_name}."
    fi
}

# Select the accelerator target and the tarball of the bot's build step to resume from, based on
# EESSI_INTERACTIVE_BUILD_ACCELERATOR and EESSI_INTERACTIVE_BUILD_RESUME_FROM, asking for what isn't set (see bot/build.sh).
# Needs EESSI_ACCELERATOR_TARGET_OVERRIDES (the accelerator targets of the build) and TARBALL_TMP_BUILD_STEP_DIR.
# Returns the accelerator target in selected_accel_target, and the tarball (or directory) in selected_tarball, which is
# the word 'none' if we shouldn't resume from anything.
select_interactive_state() {
    local -a accel_targets=("${EESSI_ACCELERATOR_TARGET_OVERRIDES[@]}")
    local -a tarball_paths
    # the n-th tarball was written after the n-th accelerator build, as each build produces one tarball
    mapfile -t tarball_paths < <(ls -tr "${TARBALL_TMP_BUILD_STEP_DIR}"/tmp_storage-* 2>/dev/null)
    local i
    for i in "${!tarball_paths[@]}"; do
        tarball_paths[$i]=$(realpath -m "${tarball_paths[$i]}")
    done
    local num_accel_targets=${#accel_targets[@]} num_tarballs=${#tarball_paths[@]}

    # show what is available, so it is easy to check that the accelerator and tarball selection belong together
    echo "bot/build.sh: interactive debugging, available state of the bot's build step:"
    echo "  accelerator targets (in the order the bot built them):"
    for i in "${!accel_targets[@]}"; do
        echo "    [$((i+1))] '${accel_targets[$i]}'"
    done
    echo "  build step tarballs in ${TARBALL_TMP_BUILD_STEP_DIR} (oldest first):"
    echo "    [0] none (do not resume from a tarball, start from scratch)"
    for i in "${!tarball_paths[@]}"; do
        echo "    [$((i+1))] $(basename "${tarball_paths[$i]}")   ($(date -r "${tarball_paths[$i]}" '+%Y-%m-%d %H:%M'), $(du -h "${tarball_paths[$i]}" | cut -f1))"
    done
    echo "  note: normally, tarball [n] is written after the n-th accelerator build, since each build should produce one tarball"
    if [[ ${num_tarballs} -ne ${num_accel_targets} ]]; then
        echo "  WARNING: ${num_tarballs} tarball(s) vs ${num_accel_targets} accelerator target(s), so tarballs cannot be paired with accelerator targets and the default is not to resume from a tarball"
    fi

    # 1. resolve what the user requested: the number of the accelerator target / tarball in the lists above (0 if not
    #    requested or, for a tarball, not in the list). EESSI_INTERACTIVE_BUILD_RESUME_FROM=none (in any case) means: don't resume
    local requested_accel="${EESSI_INTERACTIVE_BUILD_ACCELERATOR}" requested_tarball="${EESSI_INTERACTIVE_BUILD_RESUME_FROM}"
    local accel_number=0 tarball_number=0
    if [[ -n "${requested_accel}" ]]; then
        accel_number=$(position_of accel_targets "${requested_accel}" "accel/${requested_accel}")
        if [[ ${accel_number} -eq 0 ]]; then
            fatal_error "EESSI_INTERACTIVE_BUILD_ACCELERATOR='${requested_accel}' not found in accelerator targets of ${JOB_CFG_FILE}: ${accel_targets[*]}"
        fi
    fi
    if [[ -n "${requested_tarball}" && "${requested_tarball,,}" != "none" ]]; then
        tarball_number=$(position_of tarball_paths "$(realpath -m "${requested_tarball}")")
    fi

    # 2. choose what the user didn't request. If there are as many tarballs as accelerator targets, we can pair them
    #    (tarball n with accelerator target n) and suggest the one belonging to the other choice. If not, we suggest the
    #    last accelerator target and no tarball
    local counts_match=0
    [[ ${num_tarballs} -eq ${num_accel_targets} ]] && counts_match=1
    if [[ -z "${requested_accel}" ]]; then
        local default_accel_number=${num_accel_targets}
        [[ ${counts_match} -eq 1 && ${tarball_number} -gt 0 ]] && default_accel_number=${tarball_number}
        choose_option "accelerator target" EESSI_INTERACTIVE_BUILD_ACCELERATOR ${default_accel_number} 1 accel_targets
        accel_number=${CHOSEN_NUMBER}
    fi
    selected_accel_target="${accel_targets[$((accel_number-1))]}"
    if [[ -n "${requested_tarball}" ]]; then
        selected_tarball="${requested_tarball}"
    else
        local default_tarball_number=0
        [[ ${counts_match} -eq 1 ]] && default_tarball_number=${accel_number}
        choose_option "tarball to resume from (0 = none)" EESSI_INTERACTIVE_BUILD_RESUME_FROM ${default_tarball_number} 0 tarball_paths
        selected_tarball="none"
        [[ ${CHOSEN_NUMBER} -gt 0 ]] && selected_tarball="${tarball_paths[$((CHOSEN_NUMBER-1))]}"
    fi
    # accept 'none' in any capitalisation
    [[ "${selected_tarball,,}" == "none" ]] && selected_tarball="none"
    if [[ "${selected_tarball}" != "none" && ! -e "${selected_tarball}" ]]; then
        fatal_error "state to resume from does not exist: ${selected_tarball}"
    fi
}
