#!/bin/bash
set -e

CONTAINER_HOME="$(getent passwd "$(id -u)" | cut -d: -f6)"
GIT_CONFIG_PATH="${CONTAINER_HOME}/.gitconfig"
SSH_CONFIG_PATH="${CONTAINER_HOME}/.ssh/config"
DIAGNOSTIC_FAILED=0

echo "--- Starting Generalized Multi-Account Diagnostics ---"

# Check if we are in a Git repository
if [ ! -d .git ]; then
    echo "NOTICE: Not in a Git repository. Skipping deep config checks."
    exit 0
fi

# ----------------------------------------------------------------------
# 1. Check SSH Agent Functionality
# ----------------------------------------------------------------------
echo "1. Checking SSH Agent status..."
if ssh-add -l 2>/dev/null | grep -q "The agent has no identities"; then
    echo "🚨 ERROR: SSH agent is running but NO KEYS ARE LOADED."
    echo "   -> FIX: On your HOST machine, run 'ssh-add <private_key_path>' for required keys."
    DIAGNOSTIC_FAILED=1
else
    echo "✅ Agent Forwarding is ACTIVE and keys are loaded."
fi


# ----------------------------------------------------------------------
# 2. Analyze Remote URL for Custom Aliases
# ----------------------------------------------------------------------
REMOTE_URL=$(git config --get remote.origin.url 2>/dev/null)
echo "2. Analyzing remote URL: $REMOTE_URL"

if [ -z "$REMOTE_URL" ]; then
    echo "NOTICE: No remote 'origin' found. Identity switching is inactive."
    exit 0
fi

# The pattern for a custom alias is git@<custom-host>:<repo-path>
# We check for the '@' symbol followed by a non-standard host.
if [[ "$REMOTE_URL" == git@* ]]; then
    
    # Extract the hostname part (e.g., 'github.com-work' from git@github.com-work:user/repo)
    HOST_ALIAS=$(echo "$REMOTE_URL" | sed -e 's/.*@//' -e 's/:.*//')

    if [[ "$HOST_ALIAS" != "github.com" ]]; then
        # This is a custom alias, which requires ~/.ssh/config for redirection.
        
        # --- 3. Check for SSH Config File and Alias Existence ---
        echo "3. Remote uses custom alias '$HOST_ALIAS', checking SSH config..."
        
        if [ ! -f "$SSH_CONFIG_PATH" ]; then
            echo "🚨 ERROR: Custom alias used, but ~/.ssh/config NOT FOUND in container."
            echo "   -> FIX: Ensure you mount or copy your host's ~/.ssh/config file."
            DIAGNOSTIC_FAILED=1
        else
            # Check if the required custom alias exists in the config file
            if grep -q "Host $HOST_ALIAS" "$SSH_CONFIG_PATH"; then
                echo "✅ Required host alias ($HOST_ALIAS) found in config."
            else
                echo "🚨 ERROR: Alias '$HOST_ALIAS' is used in the URL but NOT DEFINED in ~/.ssh/config."
                echo "   -> FIX: Verify the alias is correctly defined in your host's SSH config file."
                DIAGNOSTIC_FAILED=1
            fi
        fi
    fi
else
    echo "NOTICE: Remote uses standard HTTPS/SSH format. Alias checks skipped."
fi


# ----------------------------------------------------------------------
# 4. Check Conditional Config File Existence (Identity Switching)
# ----------------------------------------------------------------------
echo "4. Checking for required conditional config files..."

# Find ALL conditional path entries from the auto-mounted ~/.gitconfig that use hasconfig:remote
git config --file "$GIT_CONFIG_PATH" --get-regexp '^includeIf\.hasconfig:remote.*\.path$' 2>/dev/null |
while read -r LINE; do
    
    CONFIG_FILENAME=$(echo "$LINE" | awk '{print $NF}') # e.g., .gitconfig-work
    HOST_REF_PATH="${CONTAINER_HOME}/${CONFIG_FILENAME}" # Assumes config is mounted to $HOME
    
    # Check if the file referenced in the global config is available in the container
    if [ ! -f "$HOST_REF_PATH" ]; then
        echo "🚨 ERROR: Conditional config file '$CONFIG_FILENAME' NOT FOUND."
        echo "   -> FIX: This file must be mounted or copied into $CONTAINER_HOME."
        DIAGNOSTIC_FAILED=1
    else
        # If the conditional config exists, check if its required public signing key exists
        SIGNING_KEY_PATH=$(git config --file "$HOST_REF_PATH" --get user.signingkey 2>/dev/null)
        KEY_FILENAME=$(basename "$SIGNING_KEY_PATH")

        if [[ "$SIGNING_KEY_PATH" == *".pub" ]]; then
            if [ ! -f "${CONTAINER_HOME}/.ssh/$KEY_FILENAME" ]; then
                echo "🚨 ERROR: Public signing key '$KEY_FILENAME' for identity switch is MISSING."
                echo "   -> FIX: Ensure this public key file is mounted or copied into $CONTAINER_HOME/.ssh/."
                DIAGNOSTIC_FAILED=1
            else
                 echo "✅ Conditional config ($CONFIG_FILENAME) and signing key are present."
            fi
        fi
    fi
done


# ----------------------------------------------------------------------
# Final Summary
# ----------------------------------------------------------------------
if [ "$DIAGNOSTIC_FAILED" -eq 1 ]; then
    echo "--- ❌ DIAGNOSTICS FAILED. Configuration is incomplete. ---"
    exit 1
else
    echo "--- ✅ DIAGNOSTICS PASSED. Configuration looks sound. ---"
fi
