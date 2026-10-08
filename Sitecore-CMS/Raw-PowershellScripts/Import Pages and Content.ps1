<#

PHASE 3: UNIFIED OPTIMIZELY CONTENT & MEDIA IMPORTER (TOOLBOX VERSION)

Prompts User for Target Content & Media Folders

Safely uploads and extracts the MigrationBundle.zip

Imports Media and generates thumbnails

Imports Pages and routes Local Blocks to /Data/ folders!
============================================================================
#>
Add-Type -AssemblyName System.IO.Compression.FileSystem

<# --- HELPER FUNCTIONS --- #>
function Ensure-SitecoreFolder {
param (
[string]$TargetItemPath,
[string]$RootFolder,
[string]$TemplateId = "{A87A00B1-E6DB-45AB-8B54-636FEC3B5523}"
)
$segments = $TargetItemPath.Trim('/').Split('/')
$currentBuildPath = $RootFolder

if ($segments.Length -gt 1) {
    foreach ($segment in $segments[0..($segments.Length - 2)]) {
        $nextPath = "$currentBuildPath/$segment"
        if (-not (Test-Path "master:$nextPath")) {
            New-Item -Path "master:$currentBuildPath" -Name $segment -ItemType $TemplateId | Out-Null
        }
        $currentBuildPath = $nextPath
    }
}
}

function Resolve-OptimizelyPath {
param ([string]$RawPath)

if ($RawPath -match "^/For All Sites(.*)") {
    return "/Global Blocks" + $matches[1]
}
elseif ($RawPath -match "^/Content Assets(.*)") {
    $assetsPath = $matches[1] 
    $parentPath = (Split-Path $assetsPath -Parent) -replace '\\', '/'
    $leafName = Split-Path $assetsPath -Leaf
    
    if ($parentPath -notmatch "^/Start" -and $parentPath -ne "/" -and $parentPath -ne "") {
        $parentPath = "/Start$parentPath"
    }
    
    if ($parentPath -eq "/" -or $parentPath -eq "") { return "/Start/Data/$leafName" } 
    else { return "$parentPath/Data/$leafName" }
}
else {
    return $RawPath
}
}
<# ------------------------ #>

<# ====================================================================
PHASE 1: UI & DESTINATION SETUP
==================================================================== #>
$selectedContentRoot = $null
$selectedMediaRoot = $null

$dialogParams = @{
Title = "Optimizely Content & Media Importer"
Description = "Step 1: Select the Sitecore roots where the migrated items will be stored. A 'Migrated-From-Optimizely' folder will be created automatically under both."
Width = 650
Height = 550
OkButtonName = "Next: Upload ZIP"
CancelButtonName = "Cancel"
Parameters = @(
@{
Name = "selectedContentRoot"
Title = "Select Content Root"
Source = "DataSource=/sitecore/content&Root=/sitecore/content"
editor = "item"
},
@{
Name = "selectedMediaRoot"
Title = "Select Media Library Root"
Source = "DataSource=/sitecore/media library&Root=/sitecore/media library"
editor = "item"
}
)
}

$dialogResult = Read-Variable @dialogParams

if ($dialogResult -ne "ok" -or $null -eq $selectedContentRoot -or $null -eq $selectedMediaRoot) {
Write-Host "Import cancelled by user." -ForegroundColor Yellow
exit
}

#Safely build the paths based on user selection

$baseContentPath = $selectedContentRoot.Paths.FullPath.TrimEnd('/')
$baseMediaPath = $selectedMediaRoot.Paths.FullPath.TrimEnd('/')

$contentRootPath = "$baseContentPath/Migrated-From-Optimizely"
$mediaRootPath = "$baseMediaPath/Migrated-From-Optimizely"
$defaultFolderTemplateId = "{A87A00B1-E6DB-45AB-8B54-636FEC3B5523}"

#Ensure our Wrapper Folders Exist underneath the user's selected roots

if (-not (Test-Path "master:$contentRootPath")) { New-Item -Path "master:$baseContentPath" -Name "Migrated-From-Optimizely" -ItemType $defaultFolderTemplateId | Out-Null }
if (-not (Test-Path "master:$mediaRootPath")) { New-Item -Path "master:$baseMediaPath" -Name "Migrated-From-Optimizely" -ItemType $defaultFolderTemplateId | Out-Null }

<# ====================================================================
PHASE 2: FILE UPLOAD
==================================================================== #>
$allowedLocation = [Sitecore.Configuration.Settings]::GetSetting("SPE.UploadAllowedLocation", "$SitecoreMediaFolder")
$uploadFile = $null

Write-Host "Configured upload location is: $allowedLocation" -ForegroundColor Cyan
Write-Host "Sweeping upload folder for old migration artifacts..." -ForegroundColor Gray
Get-ChildItem -Path $allowedLocation -Filter ".zip.json" -File | Remove-Item -Force -ErrorAction SilentlyContinue
Get-ChildItem -Path $allowedLocation -Filter "_Extracted" -Directory | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

try {
Write-Host "Step 2: Please select the MigrationBundle.zip to upload..." -ForegroundColor Cyan
$uploadFile = Receive-File -Path $allowedLocation -Overwrite

if ($uploadFile) { Write-Host "File successfully uploaded to: $uploadFile" -ForegroundColor Green } 
else { Write-Host "Import cancelled by user."; exit }

if (-not (Test-Path $uploadFile)) { Write-Host "File upload failed or was not found." -ForegroundColor Red; exit }

Write-Host "Extracting bundle to server memory..." -ForegroundColor Yellow
$extractFolder = "$($uploadFile)_Extracted"

if (Test-Path $extractFolder) { Remove-Item $extractFolder -Recurse -Force -ErrorAction SilentlyContinue }
[System.IO.Directory]::CreateDirectory($extractFolder) | Out-Null
[System.IO.Compression.ZipFile]::ExtractToDirectory($uploadFile, $extractFolder)

try {
    <# ====================================================================
       PHASE A: IMPORT MEDIA
       ==================================================================== #>
    $mediaMapPath = Join-Path $extractFolder "map.json"
    
    if (Test-Path $mediaMapPath) {
        Write-Host "Processing Media Library (Events enabled for file extraction)..." -ForegroundColor Cyan
        $mediaJson = Get-Content $mediaMapPath -Raw | ConvertFrom-Json
        
        foreach ($media in $mediaJson) {
            $physicalFile = Join-Path $extractFolder "assets\$($media.FileName)"
            
            if (Test-Path $physicalFile) {
                $mediaPath = "$mediaRootPath$($media.Path)"
                $targetParentPath = Split-Path $mediaPath -Parent
                $mediaName = Split-Path $mediaPath -Leaf
                
                Ensure-SitecoreFolder -TargetItemPath $media.Path -RootFolder $mediaRootPath -TemplateId $defaultFolderTemplateId

                $scItem = Get-Item -Path "master:" -ID $media.ItemId -ErrorAction SilentlyContinue

                if (-not $scItem) {
                    try {
                        $ext = [System.IO.Path]::GetExtension($physicalFile).TrimStart('.')
                        $itemName = [System.IO.Path]::GetFileNameWithoutExtension($mediaName)
                        
                        $templateId = "{1669277F-5BC7-477F-9ECB-36F445B8AB0A}" 
                        if ($ext -match '^(jpg|jpeg|png|gif|svg|bmp|webp)$') {
                            $templateId = "{F1828A2C-7E5D-4BBD-98CA-320474871548}" 
                        }

                        $scItem = New-Item -Path "master:$targetParentPath" -Name $itemName -ItemType $templateId -ForceId $media.ItemId
                        $rawItem = [Sitecore.Data.Items.Item]$scItem
                        
                        $rawItem.Editing.BeginEdit()
                        $rawItem["Extension"] = $ext
                        if ($media.AltText) { $rawItem["Alt"] = $media.AltText }
                        
                        if ($templateId -eq "{F1828A2C-7E5D-4BBD-98CA-320474871548}") {
                            $shortGuid = $media.ItemId.Replace("-", "").Replace("{", "").Replace("}", "")
                            $rawItem["__Icon"] = "-/media/$shortGuid.ashx?h=16&thn=1&w=16"
                        }
                        
                        $stream = [System.IO.File]::OpenRead($physicalFile)
                        $blobField = $rawItem.Fields["Blob"]
                        if ($blobField -ne $null) { $blobField.SetBlobStream($stream) }
                        $stream.Close()
                        
                        $rawItem.Editing.EndEdit() | Out-Null
                        Write-Host "Media created successfully to: $($scItem.Paths.FullPath)" -ForegroundColor Green 
                    } catch {
                        Write-Host "Warning: Could not create media $($mediaName). $_" -ForegroundColor Yellow
                        continue
                    }
                } else {
                    $scItem.Editing.BeginEdit()
                    if ($media.AltText) { $scItem["Alt"] = $media.AltText }
                    
                    if ($scItem.TemplateID.ToString() -eq "{F1828A2C-7E5D-4BBD-98CA-320474871548}") {
                        $shortGuid = $media.ItemId.Replace("-", "").Replace("{", "").Replace("}", "")
                        $scItem["__Icon"] = "-/media/$shortGuid.ashx?h=16&thn=1&w=16"
                    }

                    $scItem.Editing.EndEdit() | Out-Null
                    Write-Host "Media edited successfully to: $($scItem.Paths.FullPath)" -ForegroundColor Yellow
                }
            }
        }
    }

    <# ====================================================================
       PHASE B: IMPORT CONTENT (PAGES & BLOCKS)
       ==================================================================== #>
    $contentMapPath = Join-Path $extractFolder "Optimizely-content.json"
    
    if (Test-Path $contentMapPath) {
        Write-Host "Processing Pages and Blocks..." -ForegroundColor Cyan
        $contentJson = Get-Content $contentMapPath -Raw | ConvertFrom-Json
        
        <# CRITICAL: Sort-Object ensures Pages are created before Blocks #>
        $contentJson = $contentJson | Sort-Object @{Expression={$_.Path.Length}; Ascending=$true}

        foreach ($node in $contentJson) {
            
            $cleanPath = Resolve-OptimizelyPath -RawPath $node.Path
            $targetPath = "$contentRootPath$cleanPath"
            $targetParentPath = Split-Path $targetPath -Parent
            
            if (-not (Test-Path "master:$targetParentPath")) {
                Ensure-SitecoreFolder -TargetItemPath $cleanPath -RootFolder $contentRootPath -TemplateId $defaultFolderTemplateId
            }

            $scItem = Get-Item -Path "master:" -ID $node.ItemId -ErrorAction SilentlyContinue

            if (-not $scItem) {
                try {
                    $scItem = New-Item -Path "master:$targetParentPath" -Name $node.Name -ItemType $node.TemplateId -ForceId $node.ItemId
                    Write-Host "Content Item created successfully to: $($scItem.Paths.FullPath)" -ForegroundColor Green
                } catch {
                    Write-Host "Warning: Could not create $($node.Name)." -ForegroundColor Yellow
                    continue
                }
            }

            $langItem = Get-Item -Path "master:" -ID $node.ItemId -Language $node.Language -ErrorAction SilentlyContinue
            if (-not $langItem -or $langItem.Versions.Count -eq 0) {
                    $langItem = Add-ItemLanguage -Item $scItem -Language "en" -TargetLanguage $node.Language -DoNotCopyFields
                    Write-Host "Language version created successfully to: $($langItem.Paths.FullPath)" -ForegroundColor Green
            }

            $langItem.Editing.BeginEdit()
            if ($langItem.Name -ne $node.Name) { $langItem.Fields["__Display name"].Value = $node.Name }

            if ($node.Fields) {
                foreach ($property in $node.Fields.PSObject.Properties) {
                    $fieldName = $property.Name
                    $fieldValue = $property.Value
                    
                    <# --- Array to Pipe separated GUIDs (e.g. Treelist) --- #>
                    if ($fieldValue -match "^\[.*\]$") {
                        try {
                            $guidArray = $fieldValue | ConvertFrom-Json
                            if ($guidArray -is [array]) { $fieldValue = $guidArray -join "|" }
                        } catch { }
                    }

                    $safeStringValue = [string]$fieldValue
                    $targetField = $langItem.Fields[$fieldName]
                    
                    if ($targetField -ne $null) {
                        
                        <# --- FIX: SITECORE DROPTREE/DROPLINK FIELD GUID FORMATTING --- #>
                        if ($targetField.Type -eq "Image" -and $safeStringValue -match "([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})")  {
                            $extractedGuid = $matches[1].ToUpper()
                            $targetField.Value = "<image mediaid=`"{$extractedGuid}`" />"
                        } 
                        elseif (($targetField.Type -eq "Droptree" -or $targetField.Type -eq "Droplink") -and $safeStringValue -match "([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})") {
                                    $extractedGuid = $matches[1].ToUpper()
                                    $targetField.Value = "{$extractedGuid}"
                        }
                        # 3. Standard string assignment
                        else {
                            $targetField.Value = $safeStringValue
                        }
                        <# ----------------------------------------- #>
                        
                    } else {
                        Write-Host "Warning: Field '$fieldName' not found on Template '$($langItem.TemplateName)' for '$($langItem.Name)'" -ForegroundColor Yellow
                    }
                }
            }
            $langItem.Editing.EndEdit() | Out-Null
            Write-Host "Content Item edited successfully to: $($langItem.Paths.FullPath)" -ForegroundColor Yellow
        }
    }
    Write-Host "========================================================="
    Write-Host "SUCCESS! Bundle imported."
    Write-Host "========================================================="
}
finally {
    <# No context cleanup needed #>
}
}
catch {
Write-Host "An error occurred during import: $_" -ForegroundColor Red
}
finally {
Write-Host "Cleaning up temporary files..." -ForegroundColor Gray
if ($null -ne $uploadFile -and (Test-Path $uploadFile)) { Remove-Item $uploadFile -Force -ErrorAction SilentlyContinue }
if (Test-Path $extractFolder) { Remove-Item $extractFolder -Recurse -Force -ErrorAction SilentlyContinue }

# Aggressive sweep to ensure no leftover artifacts
Get-ChildItem -Path $allowedLocation -Filter "*.zip.json" -File | Remove-Item -Force -ErrorAction SilentlyContinue
Get-ChildItem -Path $allowedLocation -Filter "*_Extracted" -Directory | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue


}