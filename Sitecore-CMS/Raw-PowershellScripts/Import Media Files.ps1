<#

PHASE 3b: MEDIA-ONLY IMPORTER (TOOLBOX VERSION)

Prompts User for Target Media Library Folder using DropTree

Safely uploads and extracts the MediaOnlyBundle.zip

Imports Media, applies Sitecore GUIDs, and creates thumbnails
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
<# ------------------------ #>

<# ====================================================================
PHASE 1: UI & DESTINATION SETUP
==================================================================== #>
$selectedMediaRoot = $null

$dialogParams = @{
Title = "Optimizely Media-Only Importer"
Description = "Step 1: Select the Sitecore Media Library root where the media will be imported."
Width = 650
Height = 250
OkButtonName = "Next: Upload ZIP"
CancelButtonName = "Cancel"
Parameters = @(
@{
Name = "selectedMediaRoot"
Title = "Select Target Media Root"
Source = "DataSource=/sitecore/media library&Root=/sitecore/media library"
editor = "item"
}
)
}

$dialogResult = Read-Variable @dialogParams

if ($dialogResult -ne "ok" -or $null -eq $selectedMediaRoot) {
Write-Host "Import cancelled by user." -ForegroundColor Yellow
exit
}

#1. Safely resolve path

$mediaRootPath = $selectedMediaRoot.Paths.FullPath.TrimEnd('/')
$defaultFolderTemplateId = "{A87A00B1-E6DB-45AB-8B54-636FEC3B5523}"

#2. Smart append: Only add wrapper if they didn't already select it!

if ($mediaRootPath -notmatch "Migrated-From-Optimizely$") {
$mediaRootPath = "$mediaRootPath/Migrated-From-Optimizely"
}

#3. Ensure the Root Wrapper Folder exists

if (-not (Test-Path "master:$mediaRootPath")) {
$parent = Split-Path $mediaRootPath -Parent
$leaf = Split-Path $mediaRootPath -Leaf
New-Item -Path "master:$parent" -Name $leaf -ItemType $defaultFolderTemplateId | Out-Null
}

<# ====================================================================
PHASE 2: FILE UPLOAD & PROCESSING
==================================================================== #>
$allowedLocation = [Sitecore.Configuration.Settings]::GetSetting("SPE.UploadAllowedLocation", "$SitecoreMediaFolder")
$uploadFile = $null

Write-Host "Configured upload location is: $allowedLocation" -ForegroundColor Cyan
Get-ChildItem -Path $allowedLocation -Filter ".zip.json" -File | Remove-Item -Force -ErrorAction SilentlyContinue
Get-ChildItem -Path $allowedLocation -Filter "_Extracted" -Directory | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

try {
Write-Host "Step 2: Please select the MediaBundle.zip to upload..." -ForegroundColor Cyan
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
    $mediaMapPath = Join-Path $extractFolder "map.json"
    
    if (Test-Path $mediaMapPath) {
        Write-Host "Processing Media Library..." -ForegroundColor Cyan
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
                        
                        # Create Sitecore internal thumbnail path based on exact GUID
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
    
    Write-Host "========================================================="
    Write-Host "SUCCESS! Media Bundle imported."
    Write-Host "========================================================="
}
finally {
    <# Context Cleanup #>
}


}
catch {
Write-Host "An error occurred during import: $_" -ForegroundColor Red
}
finally {
Write-Host "Cleaning up temporary files..." -ForegroundColor Gray
if ($null -ne $uploadFile -and (Test-Path $uploadFile)) { Remove-Item $uploadFile -Force -ErrorAction SilentlyContinue }
if (Test-Path $extractFolder) { Remove-Item $extractFolder -Recurse -Force -ErrorAction SilentlyContinue }

Get-ChildItem -Path $allowedLocation -Filter "*.zip.json" -File | Remove-Item -Force -ErrorAction SilentlyContinue
Get-ChildItem -Path $allowedLocation -Filter "*_Extracted" -Directory | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue


}