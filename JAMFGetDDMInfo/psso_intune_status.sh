#!/bin/zsh --no-rcs

# EAsecureComplianceRegistrationStatus.sh
#
# Reports Jamf Conditional Access registration information for eligible
# local user accounts on multi-user Macs.

readonly DSCL="/usr/bin/dscl"
readonly ID="/usr/bin/id"
readonly DEFAULTS="/usr/bin/defaults"
readonly LAUNCHCTL="/bin/launchctl"
readonly SUDO="/usr/bin/sudo"
readonly SECURITY="/usr/bin/security"
readonly JAMF_CA="/Library/Application Support/JAMF/Jamf.app/Contents/MacOS/Jamf Conditional Access.app/Contents/MacOS/JAMF Conditional Access"

readonly COMMAND_TIMEOUT=5

# Add account names to this expression, separated by pipes.
readonly ADDITIONAL_ACCOUNTS_TO_EXCLUDE='enrollment|jamfadmin|jamfenroll|macdamin|postgres|macports|caldera'

typeset -a resultList
typeset RUN_AS_USER_OUTPUT=""
typeset RUN_AS_USER_STATUS=0
typeset RUN_AS_USER_TIMED_OUT=0

run_as_user() {
    local loggedInUser="$1"
    local userUID="$2"

    shift 2

    local outputFile=""
    local commandPID=""
    local elapsed=0

    RUN_AS_USER_OUTPUT=""
    RUN_AS_USER_STATUS=0
    RUN_AS_USER_TIMED_OUT=0

    outputFile=$(/usr/bin/mktemp -t "jamf-ca-ea.XXXXXX") || {
        RUN_AS_USER_STATUS=1
        return 1
    }

    "${LAUNCHCTL}" asuser "${userUID}" "${SUDO}" -iu "${loggedInUser}" "$@" >"${outputFile}" 2>&1 &
    commandPID=$!
    while /bin/kill -0 "${commandPID}" 2>/dev/null; do
        if (( elapsed >= COMMAND_TIMEOUT )); then
            RUN_AS_USER_TIMED_OUT=1

            /bin/kill -TERM "${commandPID}" 2>/dev/null
            /bin/sleep 1

            if /bin/kill -0 "${commandPID}" 2>/dev/null; then
                /bin/kill -KILL "${commandPID}" 2>/dev/null
            fi

            break
        fi

        /bin/sleep 1
        (( elapsed++ ))
    done

    wait "${commandPID}" 2>/dev/null
    RUN_AS_USER_STATUS=$?

    RUN_AS_USER_OUTPUT="$(<"${outputFile}")"
    /bin/rm -f "${outputFile}"

    if (( RUN_AS_USER_TIMED_OUT )); then
        return 124
    fi

    return "${RUN_AS_USER_STATUS}"
}

get_user_home() {
    local loggedInUser="$1"
    local homeRecord=""

    homeRecord="$("${DSCL}" . -read "/Users/${loggedInUser}" NFSHomeDirectory 2>/dev/null)"
    [[ "${homeRecord}" == "NFSHomeDirectory: "* ]] || return 1

    REPLY="${homeRecord#NFSHomeDirectory: }"
    [[ -n "${REPLY}" ]]
}

read_aad_registration_status() {
    local jamfAADPlist="$1"
    local aadValue=""

    aadValue="$("${DEFAULTS}" read "${jamfAADPlist}" have_an_Azure_id 2>/dev/null)"

    case "${aadValue}" in
        1|true|TRUE|YES)
            REPLY="1"
            ;;
        *)
            REPLY="0"
            ;;
    esac
}

extract_psso_value() {
    local pssoOutput="$1"
    local fieldName="$2"
    local fieldValue=""

    if [[ "${pssoOutput}" =~ "${fieldName}:[[:space:]]*([^,}\n]+)" ]]; then
        fieldValue="${match[1]}"
        fieldValue="${fieldValue//\"/}"
        fieldValue="${fieldValue##[[:space:]]#}"
        fieldValue="${fieldValue%%[[:space:]]#}"
    fi

    REPLY="${fieldValue}"
}

extract_upn() {
    local pssoOutput="$1"
    local extractedUPN=""

    if [[ "${pssoOutput}" =~ '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' ]]; then
        extractedUPN="${MATCH}"
    fi

    REPLY="${extractedUPN}"
}

extract_device_id() {
    local pssoOutput="$1"
    local extractedDeviceID=""

    if [[ "${pssoOutput}" =~ '[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}' ]]; then
        extractedDeviceID="${MATCH}"
    fi

    REPLY="${extractedDeviceID}"
}

get_legacy_wpj_key() {
    local loggedInUser="$1"
    local userUID="$2"
    local userKeychain="$3"
    local certificateOutput=""
    local line=""

    REPLY=""

    run_as_user \
        "${loggedInUser}" \
        "${userUID}" \
        "${SECURITY}" find-certificate -a -Z "${userKeychain}"

    (( RUN_AS_USER_TIMED_OUT )) && return 124
    (( RUN_AS_USER_STATUS == 0 )) || return "${RUN_AS_USER_STATUS}"

    certificateOutput="${RUN_AS_USER_OUTPUT}"

    # Preserve the current extraction behavior without passing a shell
    # pipeline as a single command argument.
    while IFS= read -r line; do
        if [[ "${line}" == *'"alis"<blob>="'* ]]; then
            line="${line#*\"alis\"<blob>=\"}"
            line="${line%%\"*}"

            if [[ -n "${line}" ]]; then
                REPLY="${line}"
                return 0
            fi
        fi
    done <<< "${certificateOutput}"

    return 1
}

get_device_compliance_registration_status() {
    local loggedInUser="$1"
    local userUID=""
    local userHome=""
    local jamfAADPlist=""
    local userSecurityPref=""
    local userKeychain=""
    local ssoStatus=""
    local aadRegistered="0"
    local pssoStatus=""
    local upn=""
    local deviceID=""
    local joinMethod=""
    local wpjKey=""

    userUID="$("${ID}" -u "${loggedInUser}" 2>/dev/null)" || {
        resultList+=("${loggedInUser}: Unable to determine user UID")
        return
    }

    get_user_home "${loggedInUser}" || {
        resultList+=("${loggedInUser}: Unable to determine user home")
        return
    }

    userHome="${REPLY}"

    if [[ ! -d "${userHome}" ]]; then
        resultList+=("${loggedInUser}: User home not found (${userHome})")
        return
    fi

    jamfAADPlist="${userHome}/Library/Preferences/com.jamf.management.jamfAAD.plist"
    userSecurityPref="${userHome}/Library/Preferences/com.apple.security.plist"
    userKeychain="${userHome}/Library/Keychains/login.keychain-db"

    if [[ ! -f "${jamfAADPlist}" ]]; then
        resultList+=("${loggedInUser}: jamfAAD plist not found (${userHome})")
        return
    fi

    if [[ ! -x "${JAMF_CA}" ]]; then
        resultList+=("${loggedInUser}: Jamf Conditional Access not installed")
        return
    fi

    read_aad_registration_status "${jamfAADPlist}"
    aadRegistered="${REPLY}"

    run_as_user "${loggedInUser}" "${userUID}" "${JAMF_CA}" getPSSOStatus

    if (( RUN_AS_USER_TIMED_OUT )); then
        resultList+=("${loggedInUser}: getPSSOStatus timed out (${userHome})")
        return
    fi

    ssoStatus="${RUN_AS_USER_OUTPUT}"

    if [[ "${ssoStatus}" == *"primary_registration_metadata_device_id"* ]]; then
        extract_psso_value "${ssoStatus}" "status"
        pssoStatus="${REPLY}"

        extract_upn "${ssoStatus}"
        upn="${REPLY}"

        extract_device_id "${ssoStatus}"
        deviceID="${REPLY}"

        case "${pssoStatus}" in
            0)
                joinMethod="pSSO Not Enabled"
                ;;
            1)
                joinMethod="pSSO Enabled, Not Registered"
                ;;
            2)
                joinMethod="pSSO Enabled and Registered"
                ;;
            3)
                joinMethod="Unknown pSSO Status"
                ;;
            "")
                joinMethod="pSSO Registered, Status Unavailable"
                ;;
            *)
                joinMethod="Unknown pSSO Status"
                ;;
        esac

        if [[ "${aadRegistered}" == "1" ]]; then
            resultList+=("${loggedInUser}: ${joinMethod} (${pssoStatus:-Unknown}) | ${upn:-NoUPNFound} | ${deviceID:-NoDeviceIDFound} | ${userHome}")
        else
            resultList+=("${loggedInUser}: WPJ key is in Secure Enclave, but AAD ID was not acquired | ${upn:-NoUPNFound} | ${deviceID:-NoDeviceIDFound} | ${userHome}")
        fi

        return
    fi

    # Legacy login-keychain registration check.
    if [[ -f "${userSecurityPref}" && -f "${userKeychain}" ]]; then
        get_legacy_wpj_key "${loggedInUser}" "${userUID}" "${userKeychain}"
        wpjKey="${REPLY}"

        if [[ -n "${wpjKey}" ]]; then
            if [[ "${aadRegistered}" == "1" ]]; then
                resultList+=("${loggedInUser}: Registered | ${userHome} | Device ID: ${wpjKey}")
            else
                resultList+=("${loggedInUser}: WPJ key present, but AAD ID was not acquired | ${userHome} | Device ID: ${wpjKey}")
            fi

            return
        fi
    fi

    resultList+=("${loggedInUser}: No WPJ Key Present | ${userHome}")
}

typeset -a userAccounts

userAccounts=("${(@f)$("${DSCL}" . -list /Users 2>/dev/null)}")

for user in "${userAccounts[@]}"; do
    [[ -z "${user}" ]] && continue
    [[ "${user}" == _* ]] && continue

    if [[ "${user}" =~ "^(daemon|nobody|root|localmgr|${ADDITIONAL_ACCOUNTS_TO_EXCLUDE})$" ]]; then
        continue
    fi

    get_device_compliance_registration_status "${user}"
done

if (( ${#resultList[@]} == 0 )); then
    echo "<result>N/A</result>"
else
    printf '<result>%s</result>\n' "${(j:\n:)resultList}"
fi