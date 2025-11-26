#!/bin/bash

set -euo pipefail

# Script to execute a full end to end transactional authorization flow
# Documentation here https://backstage.forgerock.com/docs/idcloud/latest/am-authorization/transactional-authorization.html
# Script requires "jq" be installed on the system to function

#############################
# Parameters to modify
#############################
AM_URL='https://openam-<tenant>/am'
REALM='alpha'
USER_LOGIN_JOURNEY='NormalLogin'
ADMIN_LOGIN_JOURNEY='AdminLogin'
USER_USERNAME='policy_user'
USER_PASSWORD='!!_SeCu4E@Pa55w04D$'
ADMIN_USERNAME='policy_admin'
ADMIN_PASSWORD='!!_Adm1nSeCu4E@Pa55w04D$'
POLICY_APP='transactionalAuthZ'
POLICY_RESOURCE='https://api.bankingexample.com:443/makepayment'

#############################
# No need to modify
#############################
USER_JOURNEY_URL="${AM_URL}/json/realms/root/realms/${REALM}/authenticate?authIndexType=service&authIndexValue=${USER_LOGIN_JOURNEY}"
ADMIN_JOURNEY_URL="${AM_URL}/json/realms/root/realms/${REALM}/authenticate?authIndexType=service&authIndexValue=${ADMIN_LOGIN_JOURNEY}"
AUTHN_URL="${AM_URL}/json/realms/root/realms/${REALM}/authenticate"
POLICY_URL="${AM_URL}/json/realms/root/realms/${REALM}/policies/?_action=evaluate"
CONTENT_TYPE='application/json'

# For backward compatibility an older resource version is used. Update as required.
VERSION_HEADER='resource=2.0,protocol=1.0'

# On latent network connections there may be a need to retry, hence the following curl command is used.
CURL='curl -k -s --connect-timeout 1 --max-time 5 --retry 2'

#############################
# Functions
#############################

# Checks if jq is installed, exits if not
jqCheck() {
    if ! command -v jq >/dev/null 2>&1; then
        echo >&2 "The jq command-line JSON processor is not installed on the system. Please install and re-run."
        exit 1
    fi
}

# Get the SSO cookie name from the serverinfo endpoint
getCookieName() {
    echo "Getting cookie name"
    AM_COOKIE_NAME=$($CURL "${AM_URL}/json/realms/root/serverinfo/*" | jq -er .cookieName)
    echo "CookieName is: $AM_COOKIE_NAME"
}

# Creating user token
getUserToken() {
    echo "*********************"
    echo "Creating end-user SSO token for user: ${USER_USERNAME}"
    USER_TOKEN=$($CURL \
        --request POST \
        --header "Content-Type: ${CONTENT_TYPE}" \
        --header "Accept-API-Version: ${VERSION_HEADER}" \
        --header "X-OpenAM-Username: ${USER_USERNAME}" \
        --header "X-OpenAM-Password: ${USER_PASSWORD}" \
        "${USER_JOURNEY_URL}" | jq -er .tokenId)
    echo "End-user SSO token is: ${USER_TOKEN}"
    echo "*********************"
}

# Creating admin token
getAdminToken() {
    echo "Creating policy-admin SSO token for user: ${ADMIN_USERNAME}"
    ADMIN_TOKEN=$($CURL \
        --request POST \
        --header "Content-Type: ${CONTENT_TYPE}" \
        --header "Accept-API-Version: ${VERSION_HEADER}" \
        --header "X-OpenAM-Username: ${ADMIN_USERNAME}" \
        --header "X-OpenAM-Password: ${ADMIN_PASSWORD}" \
        "${ADMIN_JOURNEY_URL}" | jq -er .tokenId)
    echo "Policy-admin SSO Token is: ${ADMIN_TOKEN}"
    echo "*********************"
}

# Calling transactional policy
initialPolicyCall() {
    echo "Calling transactional policy: ${POLICY_APP}"
    TRANSACTION_CONDITION_ADVICE_ID=$($CURL \
        --request POST \
        --header "Content-Type: ${CONTENT_TYPE}" \
        --header "Accept-API-Version: ${VERSION_HEADER}" \
        --cookie "${AM_COOKIE_NAME}=${ADMIN_TOKEN}" \
        --data "{
            \"resources\": [\"${POLICY_RESOURCE}\"],
            \"subject\": { \"ssoToken\": \"${USER_TOKEN}\" },
            \"application\": \"${POLICY_APP}\"
        }" \
        "${POLICY_URL}" | jq -er '.[0].advices.TransactionConditionAdvice[]')
    echo "Transaction Condition Advice Id is: $TRANSACTION_CONDITION_ADVICE_ID"
    echo "*********************"
}

# Call journey using TRANSACTION_CONDITION_ADVICE_ID and composite advice to get the callbacks to complete next
adviceLoginGetCallbacks() {
    echo "Calling ../authenticate endpoint with Transaction Condition Advice Id: $TRANSACTION_CONDITION_ADVICE_ID to get callbacks"

	#Needed to add -G flag
    TRANSACTIONAL_JOURNEY_JSON=$($CURL -G \
        --request POST \
        --header "Content-Type: ${CONTENT_TYPE}" \
        --header "Accept-API-Version: ${VERSION_HEADER}" \
        --cookie "${AM_COOKIE_NAME}=${USER_TOKEN}" \
        --data-urlencode 'authIndexType=composite_advice' \
        --data-urlencode "authIndexValue=<Advices>
    <AttributeValuePair>
        <Attribute name=\"TransactionConditionAdvice\"/>
        <Value>${TRANSACTION_CONDITION_ADVICE_ID}</Value>
    </AttributeValuePair>
</Advices>" \
        "${AUTHN_URL}")
    echo "*********************"
}

# Complete callbacks for later submission
adviceLoginCompleteCallbacks() {
    echo "Completing callbacks for submission"
    COMPLETED_TRANSACTIONAL_JOURNEY_JSON=$(echo "$TRANSACTIONAL_JOURNEY_JSON" | jq '
        .callbacks |= map(
            if .type == "NameCallback" then .input[0].value="'"${USER_USERNAME}"'"
            elif .type == "PasswordCallback" then .input[0].value="'"${USER_PASSWORD}"'"
            else . end
        )')

    echo "Completed callback payload:"
    echo "$COMPLETED_TRANSACTIONAL_JOURNEY_JSON" | jq -C
    echo "*********************"
}

# Call journey again with completed callback
adviceLoginSubmitCallbacks() {
    echo "Calling authenticate endpoint with advice and completed callbacks"
    $CURL \
        --request POST \
        --header "Content-Type: ${CONTENT_TYPE}" \
        --header "Accept-API-Version: ${VERSION_HEADER}" \
        --cookie "${AM_COOKIE_NAME}=${USER_TOKEN}" \
        --data "$COMPLETED_TRANSACTIONAL_JOURNEY_JSON" \
        "${AUTHN_URL}?authIndexType=composite_advice&authIndexValue=%3CAdvices%3E%0A\
%3CAttributeValuePair%3E%0A%3CAttribute%20name%3D%22TransactionConditionAdvice%22%2F%3E%0A\
%3CValue%3E${TRANSACTION_CONDITION_ADVICE_ID}%3C%2FValue%3E%0A%3C%2FAttributeValuePair%3E%0A\
%3C%2FAdvices%3E" \
        | jq .
    echo "*********************"
}

# Call policy eval again post successful AuthN with TRANSACTION_CONDITION_ADVICE_ID
finalPolicyCall() {
    echo "Finally, calling policy endpoint post transactional AuthZ with Transactional Conditional Advice Id of: $TRANSACTION_CONDITION_ADVICE_ID"
    $CURL \
        --request POST \
        --header "Content-Type: ${CONTENT_TYPE}" \
        --header "Accept-API-Version: ${VERSION_HEADER}" \
        --cookie "${AM_COOKIE_NAME}=${ADMIN_TOKEN}" \
        --data "{
            \"resources\": [\"${POLICY_RESOURCE}\"],
            \"subject\": { \"ssoToken\": \"${USER_TOKEN}\" },
            \"application\": \"${POLICY_APP}\",
            \"environment\": {
                \"TxId\": [\"${TRANSACTION_CONDITION_ADVICE_ID}\"]
            }
        }" \
        "${POLICY_URL}" | jq .
    echo "*********************"
}

#############################
# Main
#############################

clear
jqCheck
getCookieName
getUserToken
getAdminToken
initialPolicyCall
adviceLoginGetCallbacks
adviceLoginCompleteCallbacks
adviceLoginSubmitCallbacks
finalPolicyCall