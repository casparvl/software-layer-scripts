# Functions for debugging a bot build interactively, sourced by bot/build.sh if EESSI_INTERACTIVE_BUILD is set.
# See the comments at the top of bot/build.sh for the user-facing description.
#
# Requires fatal_error and echo_yellow (scripts/utils.sh).

# We can ask the user something if stdin is a terminal, or if answers are piped/redirected in (a here-string, pipe or
# file); not if stdin is /dev/null or closed (e.g. in a batch job)
can_ask() {
    [[ -t 0 || -p /dev/stdin || -f /dev/stdin ]]
}

# Ask the user to choose a number between $4 (default 1) and $2 for $1, default $3, result in INTERACTIVE_CHOICE
interactive_choice() {
    local what="$1" n="$2" default="$3" min="${4:-1}" answer
    # loop until we get a valid answer
    while true; do
        # (we print the prompt ourselves: 'read -p' only shows it if stdin is a terminal, not if answers are piped in)
        printf "bot/build.sh: select %s [%s-%s, default %s]: " "${what}" "${min}" "${n}" "${default}" >&2
        # Use the default & exit the loop if read returns non-zero, e.g. at EOF because user pressed Ctrl+D / terminal
        # disappears (avoid infinite loop)
        if ! read -r answer; then
            echo >&2
            INTERACTIVE_CHOICE=${default}
            return
        fi
        # if the answer was piped in, it isn't echoed by a terminal, so show it in the output
        [[ -t 0 ]] || echo "${answer}" >&2
        answer=${answer:-${default}}
        # Check answer is valid and return
        if [[ "${answer}" =~ ^[0-9]+$ ]] && (( answer >= min && answer <= n )); then
            INTERACTIVE_CHOICE=${answer}
            return
        fi
        echo "bot/build.sh: invalid choice '${answer}'"
    done
}

# Print the number (position in the array, starting at 1) of the first entry of the array named $1 that equals one of
# the other arguments, or 0 if none does
index_of() {
    local -n haystack="$1"
    shift
    local i needle
    for i in "${!haystack[@]}"; do
        for needle in "$@"; do
            if [[ "${haystack[$i]}" == "${needle}" ]]; then
                echo $((i+1))
                return
            fi
        done
    done
    echo 0
}

# Choose one entry of the array named $5, and return its number in CHOSEN: N for entry N of the array (counting from 1),
# and 0 for 'none' (only allowed if $4, the lowest allowed number, is 0).
#   $1 what is being chosen, $2 environment variable with which the user can set it, $3 default number, $4 lowest number
# If there is only one option, we don't need to choose. Otherwise we ask the user, if we can, or use the default and warn
choose_option() {
    local what="$1" var="$2" default="$3" min="$4"
    local -n options="$5"
    local max=${#options[@]}
    if [[ ${max} -eq ${min} ]]; then
        CHOSEN=${max}
    elif can_ask; then
        interactive_choice "${what}" ${max} ${default} ${min}
        CHOSEN=${INTERACTIVE_CHOICE}
    else
        CHOSEN=${default}
        local assumed="none"
        [[ ${CHOSEN} -gt 0 ]] && assumed="'${options[$((CHOSEN-1))]}'"
        echo_yellow "bot/build.sh: WARNING: no interactive terminal or piped input, so could not ask which ${what}. Assuming ${assumed}. To choose explicitly, set ${var}."
    fi
}

# Select the accelerator target and the tarball of the bot's build step to resume from, based on
# EESSI_INTERACTIVE_BUILD_ACCELERATOR and EESSI_INTERACTIVE_BUILD_RESUME_FROM, asking for what isn't set (see bot/build.sh).
# Needs EESSI_ACCELERATOR_TARGET_OVERRIDES (the accelerator targets of the build) and TARBALL_TMP_BUILD_STEP_DIR.
# Returns the accelerator target in selected_accel, and the tarball (or directory) in selected_tar, which is the word
# 'none' if we shouldn't resume from anything.
select_interactive_state() {
    local -a accels=("${EESSI_ACCELERATOR_TARGET_OVERRIDES[@]}")
    local -a tarballs
    # the n-th tarball was written after the n-th accelerator build, as each build produces one tarball
    mapfile -t tarballs < <(ls -tr "${TARBALL_TMP_BUILD_STEP_DIR}"/tmp_storage-* 2>/dev/null)
    local i
    for i in "${!tarballs[@]}"; do
        tarballs[$i]=$(realpath -m "${tarballs[$i]}")
    done
    local n_accel=${#accels[@]} n_tar=${#tarballs[@]}

    # show what is available, so it is easy to check that the accelerator and tarball selection belong together
    echo "bot/build.sh: interactive debugging, available state of the bot's build step:"
    echo "  accelerator targets (in the order the bot built them):"
    for i in "${!accels[@]}"; do
        echo "    [$((i+1))] '${accels[$i]}'"
    done
    echo "  build step tarballs in ${TARBALL_TMP_BUILD_STEP_DIR} (oldest first):"
    echo "    [0] none (do not resume from a tarball, start from scratch)"
    for i in "${!tarballs[@]}"; do
        echo "    [$((i+1))] $(basename "${tarballs[$i]}")   ($(date -r "${tarballs[$i]}" '+%Y-%m-%d %H:%M'), $(du -h "${tarballs[$i]}" | cut -f1))"
    done
    echo "  note: normally, tarball [n] is written after the n-th accelerator build, since each build should produce one tarball"
    if [[ ${n_tar} -ne ${n_accel} ]]; then
        echo "  WARNING: ${n_tar} tarball(s) vs ${n_accel} accelerator target(s), so tarballs cannot be paired with accelerator targets and the default is not to resume from a tarball"
    fi

    # 1. resolve what the user gave: the number of the accelerator target / tarball in the lists above (0 if not given or,
    #    for a tarball, not in the list). EESSI_INTERACTIVE_BUILD_RESUME_FROM=none (in any case) means: don't resume
    local accel_num=0 tar_num=0 given_tar="${EESSI_INTERACTIVE_BUILD_RESUME_FROM}"
    local given_accel="${EESSI_INTERACTIVE_BUILD_ACCELERATOR}"
    [[ "${given_tar,,}" == "none" ]] && given_tar="none"
    if [[ -n "${given_accel}" ]]; then
        accel_num=$(index_of accels "${given_accel}" "accel/${given_accel}")
        if [[ ${accel_num} -eq 0 ]]; then
            fatal_error "EESSI_INTERACTIVE_BUILD_ACCELERATOR='${given_accel}' not found in accelerator targets of ${JOB_CFG_FILE}: ${accels[*]}"
        fi
    fi
    if [[ -n "${given_tar}" && "${given_tar}" != "none" ]]; then
        tar_num=$(index_of tarballs "$(realpath -m "${given_tar}")")
    fi

    # 2. choose what the user didn't give. If there are as many tarballs as accelerator targets, we can pair them (tarball n
    #    with accelerator target n) and suggest the one belonging to the other choice. If not, we suggest the last
    #    accelerator target and no tarball
    local paired=0
    [[ ${n_tar} -eq ${n_accel} ]] && paired=1
    if [[ -z "${given_accel}" ]]; then
        local default=${n_accel}
        [[ ${paired} -eq 1 && ${tar_num} -gt 0 ]] && default=${tar_num}
        choose_option "accelerator target" EESSI_INTERACTIVE_BUILD_ACCELERATOR ${default} 1 accels
        accel_num=${CHOSEN}
    fi
    selected_accel="${accels[$((accel_num-1))]}"
    if [[ -z "${given_tar}" ]]; then
        local default=0
        [[ ${paired} -eq 1 ]] && default=${accel_num}
        choose_option "tarball to resume from (0 = none)" EESSI_INTERACTIVE_BUILD_RESUME_FROM ${default} 0 tarballs
        given_tar="none"
        [[ ${CHOSEN} -gt 0 ]] && given_tar="${tarballs[$((CHOSEN-1))]}"
    fi
    selected_tar="${given_tar}"
    if [[ "${selected_tar}" != "none" && ! -e "${selected_tar}" ]]; then
        fatal_error "state to resume from does not exist: ${selected_tar}"
    fi
}
