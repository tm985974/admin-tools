#region -- Services.Mail.Images.psm1 ------------------------------------------
# Concern : Pictures for formatted Additional Info snippets - no WinForms UI.
#           ConvertTo-MailImageRecord - normalises picture bytes for email:
#             PNG / JPEG / GIF only; wider than 600 px is scaled down
#             (high-quality bicubic); a result over 200 KB is re-encoded
#             (PNG, then JPEG at falling quality on a white background)
#             until it fits, or rejected. Returns Id (first 16 hex chars of
#             the SHA-1 of the final bytes - identical pictures share one
#             ID), Type (MIME) and Data (base64).
#           Import-MailImageFile    - same, from a file path.
#           Import-MailImageObject  - same, from a System.Drawing.Image
#             (clipboard paste).
#           ConvertTo-MailImageTable - saved picture store (PSCustomObject
#             from JSON, or hashtable) -> hashtable Id -> @{ Type; Data },
#             invalid entries dropped.
#           Save-MailImageTempFile  - writes a picture to the editor's temp
#             folder (%TEMP%\ADAdminMailEdit\<Id>.<ext>) so the editor can
#             display it; returns the full path.
#           Get-MailImageEditDir    - that temp folder (created on demand).
#           New-MailLinkedResource  - picture -> System.Net.Mail
#             LinkedResource with ContentId = Id, for embedding in a sent
#             message (<img src="cid:Id">).
#
#           Storage: pictures are saved per domain inside DomainDefaults.json
#           (AdditionalInfoImages - see Services.DomainDefaults.Config), so
#           they travel inside the EXE with that domain's entry and the
#           per-domain settings merge can never separate a snippet from its
#           pictures.
# Load order: 4a2 - no dependencies (System.Drawing, System.Net.Mail).
#             Loads before Services.Mail.Send (New-MailLinkedResource).
# New module: v1.5.0 (rich Additional Info).
#endregion

#region -- Get-MailImageEditDir ------------------------------------------------
function Get-MailImageEditDir {
    $dir = Join-Path ([System.IO.Path]::GetTempPath()) 'ADAdminMailEdit'
    if (-not (Test-Path $dir)) {
        try { New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null } catch { }
    }
    return $dir
}
#endregion

#region -- Get-MailImageExtension (private helper) -----------------------------
function Get-MailImageExtension {
    param([string]$Type)
    switch ($Type) {
        'image/jpeg' { return 'jpg' }
        'image/gif'  { return 'gif' }
        default      { return 'png' }
    }
}
#endregion

#region -- ConvertTo-MailImageRecord -------------------------------------------
function ConvertTo-MailImageRecord {
    <#
    .SYNOPSIS
        Normalises picture bytes for email. See module header.
    .PARAMETER Bytes
        Raw picture file bytes (any format System.Drawing can read).
    .PARAMETER MaxWidth
        Pictures wider than this are scaled down (default 600 px).
    .PARAMETER MaxBytes
        Size limit for the stored picture (default 200 KB).
    .OUTPUTS
        PSCustomObject: Success, Message, Id, Type, Data (base64), Width,
        Height. Never throws.
    #>
    param(
        [byte[]]$Bytes,
        [int]$MaxWidth = 600,
        [int]$MaxBytes = 204800
    )
    $fail = { param($msg) [PSCustomObject]@{ Success = $false; Message = $msg; Id = ''; Type = ''; Data = ''; Width = 0; Height = 0 } }
    if (-not $Bytes -or $Bytes.Length -eq 0) { return (& $fail 'The picture is empty.') }
    if ($Bytes.Length -gt 20MB) { return (& $fail 'The picture file is larger than 20 MB.') }

    Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue

    $srcStream = $null; $img = $null; $bmp = $null; $g = $null; $flat = $null; $gf = $null
    try {
        $srcStream = New-Object System.IO.MemoryStream(,$Bytes)
        try {
            $img = [System.Drawing.Image]::FromStream($srcStream)
        } catch {
            return (& $fail 'That file is not a picture Windows can read (use PNG, JPG or GIF).')
        }
        $w = $img.Width; $h = $img.Height
        if ($w -lt 1 -or $h -lt 1) { return (& $fail 'The picture has no size.') }
        if (([long]$w * [long]$h) -gt 40000000) { return (& $fail 'The picture is too large (over 40 megapixels).') }

        $fmt    = $img.RawFormat.Guid
        $isPng  = ($fmt -eq [System.Drawing.Imaging.ImageFormat]::Png.Guid)
        $isJpeg = ($fmt -eq [System.Drawing.Imaging.ImageFormat]::Jpeg.Guid)
        $isGif  = ($fmt -eq [System.Drawing.Imaging.ImageFormat]::Gif.Guid)

        $final = $null; $type = ''; $outW = $w; $outH = $h

        if ($w -le $MaxWidth -and $Bytes.Length -le $MaxBytes -and ($isPng -or $isJpeg -or $isGif)) {
            # Already email-ready: keep the original bytes (keeps GIF animation).
            $final = $Bytes
            $type  = if ($isJpeg) { 'image/jpeg' } elseif ($isGif) { 'image/gif' } else { 'image/png' }
        } else {
            if ($w -gt $MaxWidth) {
                $outW = $MaxWidth
                $outH = [int][Math]::Max(1, [Math]::Round($h * ($MaxWidth / [double]$w)))
            }
            $bmp = New-Object System.Drawing.Bitmap($outW, $outH, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
            $g   = [System.Drawing.Graphics]::FromImage($bmp)
            $g.InterpolationMode  = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $g.SmoothingMode      = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
            $g.PixelOffsetMode    = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
            $g.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
            $g.Clear([System.Drawing.Color]::Transparent)
            $g.DrawImage($img, 0, 0, $outW, $outH)

            $ms = New-Object System.IO.MemoryStream
            $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
            $png = $ms.ToArray(); $ms.Dispose()

            if ($png.Length -le $MaxBytes) {
                $final = $png; $type = 'image/png'
            } else {
                # Too big as PNG (usually a photo): flatten onto white and
                # step JPEG quality down until it fits.
                $flat = New-Object System.Drawing.Bitmap($outW, $outH, [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
                $gf   = [System.Drawing.Graphics]::FromImage($flat)
                $gf.Clear([System.Drawing.Color]::White)
                $gf.DrawImage($bmp, 0, 0, $outW, $outH)

                $codec = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() |
                         Where-Object { $_.MimeType -eq 'image/jpeg' } | Select-Object -First 1
                foreach ($q in @(85, 70, 55, 40)) {
                    $ep = New-Object System.Drawing.Imaging.EncoderParameters(1)
                    $ep.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter([System.Drawing.Imaging.Encoder]::Quality, [long]$q)
                    $ms = New-Object System.IO.MemoryStream
                    $flat.Save($ms, $codec, $ep)
                    $jpg = $ms.ToArray(); $ms.Dispose(); $ep.Dispose()
                    if ($jpg.Length -le $MaxBytes) { $final = $jpg; $type = 'image/jpeg'; break }
                }
                if (-not $final) {
                    return (& $fail ('The picture is still over ' + [int]($MaxBytes / 1024) + ' KB after shrinking. Crop it or use a simpler picture.'))
                }
            }
        }

        $sha = [System.Security.Cryptography.SHA1]::Create()
        $hash = $sha.ComputeHash($final); $sha.Dispose()
        $id = (([System.BitConverter]::ToString($hash)) -replace '-', '').ToLowerInvariant().Substring(0, 16)

        return [PSCustomObject]@{
            Success = $true
            Message = ''
            Id      = $id
            Type    = $type
            Data    = [System.Convert]::ToBase64String($final)
            Width   = $outW
            Height  = $outH
        }
    } catch {
        return (& $fail ('Could not process the picture: ' + $_.Exception.Message))
    } finally {
        if ($gf)        { try { $gf.Dispose() }        catch { } }
        if ($flat)      { try { $flat.Dispose() }      catch { } }
        if ($g)         { try { $g.Dispose() }         catch { } }
        if ($bmp)       { try { $bmp.Dispose() }       catch { } }
        if ($img)       { try { $img.Dispose() }       catch { } }
        if ($srcStream) { try { $srcStream.Dispose() } catch { } }
    }
}
#endregion

#region -- Import-MailImageFile ------------------------------------------------
function Import-MailImageFile {
    <#
    .SYNOPSIS
        Reads a picture file and returns ConvertTo-MailImageRecord's result.
    #>
    param([string]$Path)
    try {
        if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            return [PSCustomObject]@{ Success = $false; Message = 'Picture file not found.'; Id = ''; Type = ''; Data = ''; Width = 0; Height = 0 }
        }
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        return (ConvertTo-MailImageRecord -Bytes $bytes)
    } catch {
        return [PSCustomObject]@{ Success = $false; Message = ('Could not read the picture: ' + $_.Exception.Message); Id = ''; Type = ''; Data = ''; Width = 0; Height = 0 }
    }
}
#endregion

#region -- Import-MailImageObject ----------------------------------------------
function Import-MailImageObject {
    <#
    .SYNOPSIS
        Converts an in-memory System.Drawing.Image (e.g. from the clipboard)
        to PNG bytes and returns ConvertTo-MailImageRecord's result.
    #>
    param([System.Drawing.Image]$Image)
    if (-not $Image) {
        return [PSCustomObject]@{ Success = $false; Message = 'No picture on the clipboard.'; Id = ''; Type = ''; Data = ''; Width = 0; Height = 0 }
    }
    $ms = $null
    try {
        $ms = New-Object System.IO.MemoryStream
        $Image.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
        return (ConvertTo-MailImageRecord -Bytes $ms.ToArray())
    } catch {
        return [PSCustomObject]@{ Success = $false; Message = ('Could not read the pasted picture: ' + $_.Exception.Message); Id = ''; Type = ''; Data = ''; Width = 0; Height = 0 }
    } finally {
        if ($ms) { $ms.Dispose() }
    }
}
#endregion

#region -- ConvertTo-MailImageTable --------------------------------------------
function ConvertTo-MailImageTable {
    <#
    .SYNOPSIS
        Saved picture store -> hashtable Id -> @{ Type; Data }. Accepts the
        PSCustomObject ConvertFrom-Json produces, a hashtable, or $null.
        Entries with a bad ID, unknown type or non-base64 data are dropped.
    #>
    param($Images)
    $table = @{}
    if (-not $Images) { return $table }
    $pairs = @()
    if ($Images -is [System.Collections.IDictionary]) {
        foreach ($k in $Images.Keys) { $pairs += ,@([string]$k, $Images[$k]) }
    } else {
        foreach ($p in $Images.PSObject.Properties) { $pairs += ,@([string]$p.Name, $p.Value) }
    }
    foreach ($pair in $pairs) {
        $id  = $pair[0].ToLowerInvariant()
        $val = $pair[1]
        if ($id -notmatch '^[0-9a-f]{16}$' -or -not $val) { continue }
        $type = ''; $data = ''
        if ($val -is [System.Collections.IDictionary]) { $type = [string]$val['Type']; $data = [string]$val['Data'] }
        else { $type = [string]$val.Type; $data = [string]$val.Data }
        if (@('image/png', 'image/jpeg', 'image/gif') -notcontains $type) { continue }
        if (-not $data -or $data -notmatch '^[A-Za-z0-9+/]+={0,2}$') { continue }
        $table[$id] = @{ Type = $type; Data = $data }
    }
    return $table
}
#endregion

#region -- Save-MailImageTempFile ----------------------------------------------
function Save-MailImageTempFile {
    <#
    .SYNOPSIS
        Writes a picture into the editor temp folder (once - an existing
        file of the same ID is reused) and returns its full path, or '' on
        failure.
    #>
    param([string]$Id, [string]$Type, [string]$Data)
    try {
        $path = Join-Path (Get-MailImageEditDir) ($Id + '.' + (Get-MailImageExtension $Type))
        if (-not (Test-Path -LiteralPath $path)) {
            [System.IO.File]::WriteAllBytes($path, [System.Convert]::FromBase64String($Data))
        }
        return $path
    } catch {
        return ''
    }
}
#endregion

#region -- New-MailLinkedResource ----------------------------------------------
function New-MailLinkedResource {
    <#
    .SYNOPSIS
        Picture -> System.Net.Mail.LinkedResource (ContentId = Id) for an
        HTML AlternateView. The caller owns (disposes) the result via the
        MailMessage. Returns $null on bad data.
    #>
    param([string]$Id, [string]$Type, [string]$Data)
    try {
        $bytes = [System.Convert]::FromBase64String($Data)
        $ms    = New-Object System.IO.MemoryStream(,$bytes)
        $lr    = New-Object System.Net.Mail.LinkedResource($ms, $Type)
        $lr.ContentId        = $Id
        $lr.TransferEncoding = [System.Net.Mime.TransferEncoding]::Base64
        $lr.ContentType.Name = ($Id + '.' + (Get-MailImageExtension $Type))
        return $lr
    } catch {
        return $null
    }
}
#endregion

Export-ModuleMember -Function Get-MailImageEditDir, ConvertTo-MailImageRecord, Import-MailImageFile, `
    Import-MailImageObject, ConvertTo-MailImageTable, Save-MailImageTempFile, New-MailLinkedResource
