#!/bin/bash

# RouterOS Script Validator - Custom implementation
# NO robust RouterOS parsers exist, so this validates common patterns

set -e

if [ $# -eq 0 ]; then
    echo "Usage: $0 <script.rsc>"
    exit 1
fi

SCRIPT_FILE="$1"
EXIT_CODE=0

echo "🔍 Validating RouterOS script: $SCRIPT_FILE"
echo "📝 Note: No robust RouterOS parsers exist - using pattern-based validation"

if [ ! -f "$SCRIPT_FILE" ]; then
    echo "❌ Error: File $SCRIPT_FILE not found"
    exit 1
fi

# Remove comments and empty lines for cleaner analysis
CLEAN_SCRIPT=$(grep -v '^[[:space:]]*#' "$SCRIPT_FILE" | grep -v '^[[:space:]]*$')

echo "🔧 Checking RouterOS-specific syntax..."

# 1. Check for unmatched braces (critical for RouterOS)
OPEN_BRACES=$(echo "$CLEAN_SCRIPT" | grep -o '{' | wc -l)
CLOSE_BRACES=$(echo "$CLEAN_SCRIPT" | grep -o '}' | wc -l)

if [ "$OPEN_BRACES" -ne "$CLOSE_BRACES" ]; then
    echo "❌ Error: Unmatched braces - found $OPEN_BRACES '{' and $CLOSE_BRACES '}'"
    EXIT_CODE=1
fi

# 2. Check for critical RouterOS syntax errors
if grep -n '} *else{' "$SCRIPT_FILE" > /dev/null; then
    echo "❌ Error: Missing space after 'else' (RouterOS requires 'else {')"
    grep -n '} *else{' "$SCRIPT_FILE"
    EXIT_CODE=1
fi

# 3. Check for boolean syntax errors  
if grep -n 'disabled=false\|enabled=true\|disabled=true\|enabled=false' "$SCRIPT_FILE" > /dev/null; then
    echo "❌ Error: RouterOS uses yes/no not true/false in queries"
    grep -n 'disabled=false\|enabled=true\|disabled=true\|enabled=false' "$SCRIPT_FILE"
    EXIT_CODE=1
fi

# 3. Check for :do without matching } on-error or } blocks
DO_COUNT=$(echo "$CLEAN_SCRIPT" | grep -c ':do {' || true)
ON_ERROR_COUNT=$(echo "$CLEAN_SCRIPT" | grep -c '} on-error=' || true)

if [ "$DO_COUNT" -gt 0 ] && [ "$ON_ERROR_COUNT" -eq 0 ]; then
    echo "⚠️  Warning: Found :do blocks but no on-error handling"
fi

# 4. Check for :local variables without proper assignment (only obvious errors)
if grep -n '^:local[[:space:]]*$' "$SCRIPT_FILE" > /dev/null; then
    echo "❌ Error: :local declaration without variable name"
    EXIT_CODE=1
fi

# 5. Check for RouterOS command structure
INVALID_COMMANDS=$(echo "$CLEAN_SCRIPT" | grep -v '^[[:space:]]*:' | grep '^[[:space:]]*[a-z]' | grep -v '^[[:space:]]*/' || true)
if [ -n "$INVALID_COMMANDS" ]; then
    echo "⚠️  Warning: Commands should start with '/' (RouterOS paths)"
fi

# 6. Check for required CAPsMAN patterns (script-specific)
if grep -q 'caps-man\|wifi capsman' "$SCRIPT_FILE"; then
    if ! grep -q '/caps-man\|/interface wifi capsman' "$SCRIPT_FILE"; then
        echo "❌ Error: Found CAPsMAN references but missing proper command paths"
        EXIT_CODE=1
    fi
fi

# 7. Check for architecture detection in CAPsMAN scripts
if grep -q 'architecture-name' "$SCRIPT_FILE"; then
    if ! grep -q 'arm\|arm64' "$SCRIPT_FILE"; then
        echo "⚠️  Warning: Architecture detection found but no ARM/ARM64 handling"
    fi
fi

# 8. Check for basic RouterOS constructs
BASIC_CHECKS=(
    "/system package update:System package update commands"
    ":log:Logging statements" 
    ":put:Output statements"
    ":if.*do=:Conditional statements"
)

for check in "${BASIC_CHECKS[@]}"; do
    pattern="${check%%:*}"
    desc="${check##*:}"
    if ! grep -q "$pattern" "$SCRIPT_FILE"; then
        echo "⚠️  Warning: No $desc found (might be expected for some scripts)"
    fi
done

echo "📊 RouterOS validation complete!"

if [ $EXIT_CODE -eq 0 ]; then
    echo "✅ No critical syntax errors found"
else
    echo "❌ Critical syntax errors found - fix before deployment"
fi

exit $EXIT_CODE
