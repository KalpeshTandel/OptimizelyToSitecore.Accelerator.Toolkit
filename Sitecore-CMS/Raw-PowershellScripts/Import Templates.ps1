# ============================================================================
# PHASE 2: Import OPTIMIZELY TEMPLATES INTO SITECORE XMC
# Reads the JSON manifest and builds Sitecore Templates using exact GUIDs.
# Includes dynamic Sections/Tabs based on Optimizely Groups.
# ============================================================================

# --- Wipe session variables from previous runs! ---
$selectedRoots = $null
$uploadFile = $null

# 1. Launch the UI Dialog
$dialogParams = @{
    Title = "Optimizely Template Importer"
    Description = "Step 1: Select the Sitecore folder where you want to create the templates."
    Width = 600
    Height = 500
    OkButtonName = "Next: Upload JSON"
    CancelButtonName = "Cancel"
    Parameters = @(
        @{
            Name = "selectedRoots"
            Title = "Select the Template folder"
            # Locks the tree to the Templates directory
            Source = "DataSource=/sitecore/templates&Root=/sitecore/templates" 
            editor = "item"
        }
    )
}

$dialogResult = Read-Variable @dialogParams

# 2. Exit if user clicks cancel or selects nothing
if ($dialogResult -ne "ok" -or $null -eq $selectedRoots -or $selectedRoots.Count -eq 0) {
    Write-Host "Export cancelled."
    exit
}

# 1. Prompt the user to upload the JSON file
Write-Host "Please select the 'Optimizely-templates.json' file..."
Write-Host "$([Sitecore.Configuration.Settings]::SitecoreMediaFolder)"

# 1. Fetch the exact allowed location from Sitecore Configuration
$allowedLocation = [Sitecore.Configuration.Settings]::GetSetting("SPE.UploadAllowedLocation", "$SitecoreMediaFolder")

Write-Host "Sweeping upload folder for old artifacts..." -ForegroundColor Gray
Get-ChildItem -Path $allowedLocation -Filter "*.json" -File | Remove-Item -Force -ErrorAction SilentlyContinue

# 3. Inform the user
Write-Host "Configured upload location is: $allowedLocation" -ForegroundColor Cyan

# 4. Use Receive-File with the mandatory -Path parameter
try {
    $uploadFile = Receive-File -Path $allowedLocation -Overwrite
    
    if ($uploadFile) {
        Write-Host "File successfully uploaded to: $fullTargetPath" -ForegroundColor Green
    } else {
        Write-Host "Import cancelled by user."
        exit
    }
    # Read and parse the JSON file
    $jsonContent = Get-Content $uploadFile -Raw | ConvertFrom-Json
    $templateCount = $jsonContent.Count

    Write-Host "Successfully loaded $templateCount templates from JSON. Starting import..."
}
catch {
    Write-Host "An error occurred during file reception: $_" -ForegroundColor Red
    exit
}
finally{
    Remove-Item $uploadFile -Force -ErrorAction SilentlyContinue
}




# 2. Define the Target Folder in Sitecore (Where templates will be created)
$targetRoot = "$($selectedRoots.Paths.FullPath)/Migrated-From-Optimizely"
Write-Host $selectedRoots.Paths.FullPath

Write-Host $targetRoot

$folderTemplateId = "{0437FEE2-44C9-46A6-ABE9-28858D9FEE8C}" # Standard Template Folder
$sysTemplateId = "{AB86861A-6030-46C5-B394-E8F99E8B87DB}" # System/Templates/Template
$sysSectionId = "{E269FBB5-3750-427A-9149-7AA950B49301}" # System/Templates/Template section
$sysFieldId = "{455A3E98-A627-4B40-8035-E683A0331AC7}" # System/Templates/Template field
$baseTemplateId = "{1930BBEB-7805-471A-A3BE-4858AC7CF696}" # Sitecore Standard Template


# Ensure the root folder exists
if (-not (Test-Path $targetRoot)) {
    New-Item -Path "master:\$($selectedRoots.Paths.FullPath)" -Name "Migrated-From-Optimizely" -ItemType $folderTemplateId | Out-Null
    Write-Host "Created root folder: $targetRoot"
}

# 3. Loop through and create Templates
foreach ($optiTemplate in $jsonContent) {
    $templatePath = "$targetRoot/$($optiTemplate.Name)"
    
    $templateItem = Get-Item -Path "master:" -ID $optiTemplate.TemplateId -ErrorAction SilentlyContinue
    
    # Create the Template if it doesn't exist (Forcing the Optimizely GUID)
    if (-not $templateItem) {
        $templateItem = New-Item -Path "master:\$targetRoot" -Name $optiTemplate.Name -ItemType $sysTemplateId -ForceId $optiTemplate.TemplateId
        Write-Host "Created Template: $($optiTemplate.Name)" -ForegroundColor Green
    } else {
        Write-Host "Updated Template: $($optiTemplate.Name)" -ForegroundColor Yellow
    }

    # Set the Display Name and Base Template
    $templateItem.Editing.BeginEdit()
    $templateItem["__Display name"] = $optiTemplate.DisplayName
    $templateItem["__Base template"] = $baseTemplateId
    $templateItem.Editing.EndEdit() | Out-Null

    # 4. Create the Sections and Fields Dynamically
    foreach ($field in $optiTemplate.Fields) {
        
        $sectionName = $field.SectionName
        if ([string]::IsNullOrWhiteSpace($sectionName)) { $sectionName = "Content" }
        
        $sectionItem = Get-ChildItem -Path "master:\$($templateItem.Paths.FullPath)" | Where-Object { $_.Name -eq $sectionName }

        if (-not $sectionItem) {
            $sectionItem = New-Item -Path "master:\$($templateItem.Paths.FullPath)" -Name $sectionName -ItemType $sysSectionId
        }
        # ----------------------------------

        $fieldItem = Get-Item -Path "master:" -ID $field.FieldId -ErrorAction SilentlyContinue
        
        if (-not $fieldItem) {
            $fieldItem = New-Item -Path "master:\$($sectionItem.Paths.FullPath)" -Name $field.Name -ItemType $sysFieldId -ForceId $field.FieldId
        }

        # Apply mapped Field Types, Display Names, and Shared configuration
        $fieldItem.Editing.BeginEdit()
        
        $fieldItem["Type"] = $field.SitecoreFieldType
        $fieldItem["Title"] = $field.DisplayName
        $fieldItem["__Sortorder"] = $field.SortOrder
        
        if ($field.IsShared) {
            $fieldItem["Shared"] = "1"
        } else {
            $fieldItem["Shared"] = "0"
        }

        $fieldItem.Editing.EndEdit() | Out-Null
    }
}

Write-Host "========================================================="
Write-Host "SUCCESS! All templates, sections, and fields have been imported."
Write-Host "You can view them at: /sitecore/templates/Project/Migrated-From-Optimizely"
Write-Host "========================================================="