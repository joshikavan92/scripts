#!/bin/bash

# === CONFIGURATION ===
jamfProURL="https://server.jamfcloud.com"
apiUser="username"
apiPass='password'  # Use single quotes to avoid special char interpretation

# === GET SERIAL NUMBER OF USER's MAC ===
serialNumber=$(system_profiler SPHardwareDataType | awk '/Serial Number/{print $NF}')

# === REQUEST AUTH TOKEN ===
authToken=$(curl --silent --request POST \
    --url "$jamfProURL/api/v1/auth/token" \
    --user "$apiUser:$apiPass")

# === PARSE AUTH TOKEN ===
token=$(plutil -extract token raw - <<< "$authToken" 2>/dev/null)

if [ -z "$token" ]; then
    echo "Error: Failed to obtain authentication token"
    exit 1
fi

# === CALL CLASSIC API WITH SERIAL NUMBER ===
computerXML=$(curl -s \
  -H "Authorization: Bearer $token" \
  -H "accept: application/xml" \
  "$jamfProURL/JSSResource/computers/serialnumber/$serialNumber")

# === PARSE LOCATION USERNAME ===
jamfUsername=$(echo "$computerXML" | xmllint --xpath "//computer/location/username/text()" - 2>/dev/null)

if [ -z "$jamfUsername" ]; then
    echo "Error: Could not retrieve username from Jamf"
    exit 1
fi

# === TEST USER MEMBERSHIP FOR CLOUD IDP GROUP ===
membershipCheck=$(curl -s --request POST \
     --url "$jamfProURL/api/v1/cloud-idp/1001/test-user-membership" \
     --header "Authorization: Bearer $token" \
     --header "Accept: application/json" \
     --header "Content-Type: application/json" \
     --data '{
       "username": "'"$jamfUsername"'",
       "groupname": "UserGroupName"
     }')

# === PARSE isMember VALUE ===
isMember=$(echo "$membershipCheck" | grep -o '"isMember" : \w*' | cut -d':' -f2 | tr -d ' ')

if [ "$isMember" = "true" ]; then
    userRole="admin"
else
    userRole="standard"
fi

# === FUNCTION TO CONVERT USER ROLE ===
convert_user_role() {
    local localUser="$1"
    local role="$2"

    if [ -z "$localUser" ] || [ -z "$role" ]; then
        echo "Error: Username or role not provided"
        return 1
    fi

    if ! id "$localUser" &>/dev/null; then
        echo "Error: User $localUser does not exist on this Mac"
        return 1
    fi

    local isAdmin=$(dscl . -read /Groups/admin GroupMembership 2>/dev/null | grep -w "$localUser")

    if [ "$role" = "admin" ]; then
        echo "Converting $localUser to admin..."
        if [ -n "$isAdmin" ]; then
            echo "$localUser is already an admin"
        else
            sudo dscl . -append /Groups/admin GroupMembership "$localUser"
            if [ $? -eq 0 ]; then
                echo "Successfully converted $localUser to admin"
            else
                echo "Failed to convert $localUser to admin"
                return 1
            fi
        fi
    elif [ "$role" = "standard" ]; then
        echo "Converting $localUser to standard user..."
        if [ -z "$isAdmin" ]; then
            echo "$localUser is already a standard user"
        else
            sudo dscl . -delete /Groups/admin GroupMembership "$localUser"
            if [ $? -eq 0 ]; then
                echo "Successfully converted $localUser to standard user"
            else
                echo "Failed to convert $localUser to standard user"
                return 1
            fi
        fi
    else
        echo "Error: Invalid role specified"
        return 1
    fi

    return 0
}

# === MAP JAMF USERNAME TO LOCAL MAC USERNAME (if needed) ===
# Assuming they’re same, else you can customize this
localUsername="$jamfUsername"

echo "Converting user $localUsername to $userRole role..."
convert_user_role "$localUsername" "$userRole"

# === OUTPUT FINAL STATUS ===
if [ $? -eq 0 ]; then
    echo "User conversion completed successfully"
    exit 0
else
    echo "User conversion failed"
    exit 1
fi
