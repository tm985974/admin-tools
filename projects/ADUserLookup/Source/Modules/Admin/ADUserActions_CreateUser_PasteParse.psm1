#region -- ADUserActions.CreateUser.PasteParse.psm1 --------------------------
# Concern : ConvertFrom-PastedUserText - pure text parser for the Paste Import
#           panel on the Create New User screen. Converts "Key: Value" user
#           blocks copied from the business domain into an array of record
#           objects. No UI, no AD calls, no script-scope state.
# Load order: 37a - no dependencies.
# Consumers : ADUserActions.CreateUser.PasteQueue (Parse button).
#
# Input format (one block per user, blank line between users):
#   First name: John
#   Last name: Smith
#   Account name: jsmith
#   Telephone: 555-123-4567
#   Email: jsmith@business.com
#
# Parsing rules:
#   - Keys are matched case-insensitively after stripping everything except
#     letters, so "First name", "FirstName", "first_name" and "FIRST NAME"
#     all resolve to FirstName. "E-mail" resolves to Email.
#   - A new record starts on a blank line, OR when a key that the current
#     record already holds appears again (covers pastes with no blank lines
#     between users, e.g. a second "First name:" line).
#   - Lines without a "Key:" prefix and unrecognised keys are ignored.
#   - Values are trimmed; non-breaking spaces are normalised to spaces.
#   - Account name is reduced to the bare SAM if pasted as DOMAIN\sam or as
#     sam@domain (UPN form).
#   - Optional aliases mapped when present: Job title / Title, Department,
#     Company, Office. Absent keys simply stay blank.
#
# Validation (per record):
#   - Missing First name or Last name     -> Status 'Invalid'
#   - Account name repeated in this paste -> Status 'Invalid' (later copy)
#   - Email present but malformed         -> Issue noted, Status stays
#                                            'Pending' (Email is optional)
#   - Everything else                      -> Status 'Pending'
#   Account name is optional - a blank one means the Create User panel
#   falls back to the domain naming convention built from First/Last.
#
# Record shape (PSCustomObject):
#   Index, FirstName, LastName, AccountName, Telephone, Email,
#   Title, Department, Company, Office, Status, Issue
#endregion

#region -- ConvertFrom-PastedUserText -----------------------------------------
function ConvertFrom-PastedUserText {
    <#
    .SYNOPSIS
        Parses pasted business-domain user blocks into record objects.
    .PARAMETER Text
        Raw text from the Paste Import textbox.
    .OUTPUTS
        PSCustomObject[] - one record per user block, in paste order. Empty
        array when no recognisable user data is found.
    #>
    param([string]$Text)

    $results = New-Object System.Collections.Generic.List[object]
    if ([string]::IsNullOrWhiteSpace($Text)) { return $results.ToArray() }

    # Normalised key -> record field
    $keyMap = @{
        'firstname'       = 'FirstName'
        'givenname'       = 'FirstName'
        'first'           = 'FirstName'
        'lastname'        = 'LastName'
        'surname'         = 'LastName'
        'familyname'      = 'LastName'
        'sn'              = 'LastName'
        'last'            = 'LastName'
        'accountname'     = 'AccountName'
        'samaccountname'  = 'AccountName'
        'logonname'       = 'AccountName'
        'userlogonname'   = 'AccountName'
        'username'        = 'AccountName'
        'account'         = 'AccountName'
        'telephone'       = 'Telephone'
        'telephonenumber' = 'Telephone'
        'phone'           = 'Telephone'
        'phonenumber'     = 'Telephone'
        'officephone'     = 'Telephone'
        'email'           = 'Email'
        'emailaddress'    = 'Email'
        'mail'            = 'Email'
        'jobtitle'        = 'Title'
        'title'           = 'Title'
        'department'      = 'Department'
        'dept'            = 'Department'
        'company'         = 'Company'
        'office'          = 'Office'
    }
    $fieldNames = @('FirstName','LastName','AccountName','Telephone','Email',
                    'Title','Department','Company','Office')

    $linePattern = '^\s*([A-Za-z][A-Za-z0-9 _.\-]{0,40}?)\s*:\s*(.*?)\s*$'
    $nbsp        = [string][char]0x00A0

    # Raw blocks: each is a hashtable of field -> value
    $blocks  = New-Object System.Collections.Generic.List[hashtable]
    $current = @{}

    $lines = $Text -split "`r?`n"
    foreach ($rawLine in $lines) {
        $line = $rawLine.Replace($nbsp, ' ')

        if ([string]::IsNullOrWhiteSpace($line)) {
            if ($current.Count -gt 0) {
                $blocks.Add($current)
                $current = @{}
            }
            continue
        }

        $m = [System.Text.RegularExpressions.Regex]::Match($line, $linePattern)
        if (-not $m.Success) { continue }

        $normKey = ($m.Groups[1].Value.ToLower() -replace '[^a-z]', '')
        if (-not $keyMap.ContainsKey($normKey)) { continue }

        $field = $keyMap[$normKey]
        $value = $m.Groups[2].Value.Trim()

        # A key the current block already holds starts a new user
        if ($current.ContainsKey($field)) {
            $blocks.Add($current)
            $current = @{}
        }
        $current[$field] = $value
    }
    if ($current.Count -gt 0) { $blocks.Add($current) }

    # Build record objects
    $seenAccounts = @{}
    $idx = 0
    foreach ($b in $blocks) {
        $idx++
        $vals = @{}
        foreach ($f in $fieldNames) {
            if ($b.ContainsKey($f)) { $vals[$f] = [string]$b[$f] } else { $vals[$f] = '' }
        }

        # DOMAIN\sam or sam@domain -> sam
        $acct = $vals['AccountName']
        if ($acct -match '\\') { $acct = $acct.Substring($acct.LastIndexOf('\') + 1) }
        if ($acct -match '@')  { $acct = $acct.Substring(0, $acct.IndexOf('@')) }
        $vals['AccountName'] = $acct.Trim()

        $status = 'Pending'
        $issues = New-Object System.Collections.Generic.List[string]

        if (-not $vals['FirstName'] -or -not $vals['LastName']) {
            $status = 'Invalid'
            $issues.Add('Missing First name or Last name.')
        }

        if ($vals['AccountName']) {
            $acctKey = $vals['AccountName'].ToLower()
            if ($seenAccounts.ContainsKey($acctKey)) {
                $status = 'Invalid'
                $issues.Add("Duplicate account name in paste (see #$($seenAccounts[$acctKey])).")
            } else {
                $seenAccounts[$acctKey] = $idx
            }
        }

        if ($vals['Email'] -and ($vals['Email'] -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$')) {
            $issues.Add('Email format looks invalid.')
        }

        $results.Add([PSCustomObject]@{
            Index       = $idx
            FirstName   = $vals['FirstName']
            LastName    = $vals['LastName']
            AccountName = $vals['AccountName']
            Telephone   = $vals['Telephone']
            Email       = $vals['Email']
            Title       = $vals['Title']
            Department  = $vals['Department']
            Company     = $vals['Company']
            Office      = $vals['Office']
            Status      = $status
            Issue       = ($issues -join ' ')
        })
    }

    return $results.ToArray()
}
#endregion

Export-ModuleMember -Function ConvertFrom-PastedUserText
