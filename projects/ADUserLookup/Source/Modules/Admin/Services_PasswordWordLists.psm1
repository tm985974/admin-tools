#region -- Services.PasswordWordLists.psm1 ------------------------------------
# Concern : Single source of truth for the password generator's three word
#           lists (Phrase, Symbol, Number), backed by a JSON config file under
#           .\Config\PasswordGenerator.json. Shared by ADUserActions.
#           PasswordGenerator (New-GeneratedPassword) and ADTools.
#           PasswordGenerator.Engine (New-CustomPassword) so both draw from
#           the same editable lists - no duplicated word data anywhere else.
#           Get-PasswordWordLists - loads the 3 lists, seeding the file with
#             defaults on first run if it does not exist yet.
#           Set-PasswordWordLists - validates and saves all 3 lists at once
#             (single-Update model - partial saves are not supported by design).
# Load order: 4a - no dependencies on other AD-Admin modules. Must load before
#             ADUserActions.PasswordGenerator (#29) and ADTools.
#             PasswordGenerator.Engine (#114), both of which call
#             Get-PasswordWordLists.
# New module: created to unify the two previously-independent word-list
#             copies (ADUserActions.PasswordGenerator's hardcoded arrays and
#             ADTools.PasswordGenerator.Engine's broken tab-options fallback)
#             into one editable, persisted source.
#endregion

#region -- Default seed lists (first-run only) --------------------------------
# These populate PasswordGenerator.json the first time it is created. After
# that, the file is authoritative - these arrays are never read again unless
# the file is missing or unreadable.
$script:PwDefaultPhrase = @(
    "Casablanca","Ghostbusters","Interstellar","Ratatouille","Braveheart",
    "Unbreakable","Beetlejuice","ForrestGump","PulpFiction","BladeRunner",
    "FindingNemo","CitizenKane","Goodfellas","TaxiDriver","ThePrestige",
    "JurassicPark","TheGodfather","OceansEleven","PurpleRain","CrazyTrain",
    "LoseYourself","NovemberRain","Wonderwall","BillieJean","Hallelujah",
    "Radioactive","CountingStars","Photograph","Satisfaction","PaintItBlack",
    "Celebration","Complicated","Girlfriend","OneMoreTime","EveryBreath",
    "DesertRose","FieldsOfGold","Englishman","AllForLove","HeavenBryan",
    "TheHangover","Bridesmaids","TheOtherGuys","StepBrothers","ThisIsTheEnd",
    "TheWizardofOz","TheTerminator","Independence","TheFugitive","TrueRomance",
    "ReservoirDogs","ApocalypseNow","TheExorcist","TheRevenant","TheDeparted",
    "AmericanBeauty","ZodiacFilm","SevenFincher","ThreeHundred","VforVendetta",
    "AlienRidley","Prometheus","ChildrenofMen","ThorRagnarok","IronManTony",
    "CaptainAmerica","BlackPanther","DoctorStrange","Armageddon","Trainspotting",
    "Nightcrawler","TotalRecall","TheHurtLocker","AmericanPsycho","ShutterIsland",
    "GoneBabyGone","MysticRiver","TheAvengers","TheDarkKnight","BatmanBegins",
    "ManofSteel","WonderWoman","WolverineXmen","XMenFirstClass","TheIncredibles",
    "HelloWorld","GoodMorning","SeeYouLater","ThankYouSoMuch","HaveANiceDay",
    "TakeItEasy","PieceOfCake","AwesomeSauce","SuperDuper","AbsolutelyYes",
    "ChickenNugget","BaconLover","PizzaIsLife","TacoTuesday","CookieMonster",
    "CoffeeLover","PeanutButter","CoolYourJets","HoldYourHorses","SpillTheBeans",
    "WhatTheHeck","LetsGoTeam","LevelUpNow","StayHumble","KeepItReal",
    "TrustMeBro","ForRealThough","ChillVibes","GoodVibesOnly","PositiveEnergy",
    "HappyPlace","KeepSmiling","RockAndRoll","TotallyTrue","AbsoluteUnit",
    "NinjaMoves","PirateLife","CowboyMode","RobotDance","DragonSlayer",
    "CtrlAltDel","BufferingNow","LoadingBar","ChocolateBar","CottonCandy"
)
$script:PwDefaultSymbol = @("!","@","#","$","%","^","&","*","+","?")
$script:PwDefaultNumber = 1980..2035 | ForEach-Object { "$_" }
#endregion

#region -- Get-PwConfigPath (private helper) -----------------------------------
function Get-PwConfigPath {
    $dir = if ($script:ConfigDir) { $script:ConfigDir }
           elseif ($script:RootDir) { Join-Path $script:RootDir 'Config' }
           else { Join-Path $PWD.Path 'Config' }
    if (-not (Test-Path $dir)) {
        try { New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null } catch { }
    }
    return (Join-Path $dir 'PasswordGenerator.json')
}
#endregion

#region -- Get-PasswordWordLists ------------------------------------------------
function Get-PasswordWordLists {
    <#
    .SYNOPSIS
        Returns a PSCustomObject with Phrase, Symbol, and Number arrays, read
        from .\Config\PasswordGenerator.json. Creates the file with seed
        defaults if it does not exist yet. Falls back to the seed defaults
        (without overwriting the file) if the file exists but cannot be
        parsed, so a corrupt file never breaks password generation.
    #>
    $path = Get-PwConfigPath

    if (-not (Test-Path $path)) {
        $seed = [PSCustomObject]@{
            Phrase = @($script:PwDefaultPhrase)
            Symbol = @($script:PwDefaultSymbol)
            Number = @($script:PwDefaultNumber)
        }
        try { ($seed | ConvertTo-Json -Depth 4) | Out-File -FilePath $path -Encoding UTF8 -ErrorAction Stop } catch { }
        return $seed
    }

    try {
        $raw = Get-Content -Path $path -Raw -Encoding UTF8 -ErrorAction Stop
        $obj = $raw | ConvertFrom-Json -ErrorAction Stop
        $phrase = @($obj.Phrase | Where-Object { $_ -and "$_".Trim() -ne '' })
        $symbol = @($obj.Symbol | Where-Object { $_ -and "$_".Trim() -ne '' })
        $number = @($obj.Number | Where-Object { $_ -and "$_".Trim() -ne '' })
        if ($phrase.Count -eq 0) { $phrase = @($script:PwDefaultPhrase) }
        if ($symbol.Count -eq 0) { $symbol = @($script:PwDefaultSymbol) }
        if ($number.Count -eq 0) { $number = @($script:PwDefaultNumber) }
        return [PSCustomObject]@{ Phrase = $phrase; Symbol = $symbol; Number = $number }
    } catch {
        return [PSCustomObject]@{
            Phrase = @($script:PwDefaultPhrase)
            Symbol = @($script:PwDefaultSymbol)
            Number = @($script:PwDefaultNumber)
        }
    }
}
#endregion

#region -- Set-PasswordWordLists ------------------------------------------------
function Set-PasswordWordLists {
    <#
    .SYNOPSIS
        Cleans (trim, drop blank, de-duplicate) and saves all 3 lists at once
        to .\Config\PasswordGenerator.json. All-or-nothing: if any list ends
        up empty after cleaning, nothing is written and Success is $false, so
        a save can never leave a list empty (which would break Get-Random).
    .PARAMETER Phrase
        Raw phrase lines (one item per array entry - caller splits on newline).
    .PARAMETER Symbol
        Raw symbol lines.
    .PARAMETER Number
        Raw number lines.
    .OUTPUTS
        PSCustomObject with Success (bool), Message (string), and Lists
        (PSCustomObject with the cleaned Phrase/Symbol/Number arrays - present
        only when Success is $true, reflects what was actually written).
    #>
    param(
        [string[]]$Phrase,
        [string[]]$Symbol,
        [string[]]$Number
    )

    $cleanPhrase = @($Phrase | ForEach-Object { "$_".Trim() } | Where-Object { $_ -ne '' } | Select-Object -Unique)
    $cleanSymbol = @($Symbol | ForEach-Object { "$_".Trim() } | Where-Object { $_ -ne '' } | Select-Object -Unique)
    $cleanNumber = @($Number | ForEach-Object { "$_".Trim() } | Where-Object { $_ -ne '' } | Select-Object -Unique)

    if ($cleanPhrase.Count -eq 0) { return [PSCustomObject]@{ Success = $false; Message = 'Phrase list cannot be empty.' } }
    if ($cleanSymbol.Count -eq 0) { return [PSCustomObject]@{ Success = $false; Message = 'Symbol list cannot be empty.' } }
    if ($cleanNumber.Count -eq 0) { return [PSCustomObject]@{ Success = $false; Message = 'Number list cannot be empty.' } }

    $path   = Get-PwConfigPath
    $result = [PSCustomObject]@{ Phrase = $cleanPhrase; Symbol = $cleanSymbol; Number = $cleanNumber }

    try {
        ($result | ConvertTo-Json -Depth 4) | Out-File -FilePath $path -Encoding UTF8 -ErrorAction Stop
        return [PSCustomObject]@{ Success = $true; Message = 'Saved.'; Lists = $result }
    } catch {
        return [PSCustomObject]@{ Success = $false; Message = "Save failed: $($_.Exception.Message)" }
    }
}
#endregion

Export-ModuleMember -Function `
    Get-PasswordWordLists, `
    Set-PasswordWordLists
