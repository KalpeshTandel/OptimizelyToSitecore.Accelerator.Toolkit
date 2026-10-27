# 🚀 Optimizely to Sitecore Accelerator Toolkit

The **Optimizely to Sitecore Accelerator Toolkit** is an enterprise-grade utility designed to accelerate the migration of Data Templates, Media, and Content from Optimizely PaaS CMS 12 (.NET 8) to Sitecore (XM / XP / XM Cloud).

This toolkit operates in a decoupled ETL (Extract, Transform, Load) architecture, completely removing the need for messy, one-off migration scripts. It utilizes Optimizely Scheduled Jobs for safe data extraction and Sitecore PowerShell Extensions (SPE) for automated code generation and data ingestion.

## 🏗️ Architecture Overview

```mermaid
graph LR
    A[Optimizely CMS 12] -->|Scheduled Jobs| B(JSON / ZIP Bundles)
    B -->|Manual Transfer| C(Sitecore Server)
    C -->|PowerShell Extensions| D[Sitecore XM/XP/XMC]
    
    style A fill:#0037ff,stroke:#0037ff,color:#fff
    style D fill:#eb1f2a,stroke:#eb1f2a,color:#fff
    style B fill:#f9f9f9,stroke:#333,stroke-width:2px,stroke-dasharray: 5 5
```
### 📹 See it in Action: Full Walkthrough
[![Watch the Migration Walkthrough](https://img.youtube.com/vi/0Q2YelGb3wU/hqdefault.jpg)](https://www.youtube.com/watch?v=0Q2YelGb3wU)

*Click the image above to watch the full step-by-step video walkthrough.*

Direct Link - https://www.youtube.com/watch?v=0Q2YelGb3wU

## ⚡ Quick Start

1. **Optimizely:** Install the `OptimizelyToSitecore.Accelerator.Toolkit` NuGet package in your CMS 12 project.
2. **Sitecore:** Install the Sitecore Package (`.zip`) or SCS item package (`.itempackage`) provided in the `/Installers` directory.
3. **Extract:** Run the extraction scheduled jobs in Optimizely to generate your schema and content payloads.
4. **Load:** Use the new Sitecore PowerShell toolbox scripts to upload the payloads and instantly generate your items.

---

## 1. Installation Guide

The toolkit consists of two halves: the **Optimizely Extraction Engine** and the **Sitecore Import Scripts**.

### A. Installing the Optimizely Extraction Engine
The Optimizely export jobs are packaged as a standard `.nupkg` file (e.g., `OptimizelyToSitecore.Accelerator.Toolkit.8.10.26.nupkg`) located in the `Installers/` directory of this repository.
- ⏬ **Download:** [OptimizelyToSitecore.Accelerator.Toolkit.8.10.26.nupkg](https://github.com/KalpeshTandel/OptimizelyToSitecore.Accelerator.Toolkit/tree/main/Installers)

1. Place the provided `.nupkg` file in your local NuGet feed directory (e.g., `C:\LocalNuGet`).
2. Open your Optimizely web project directory in Visual Studio.
3. Add a new Package Source to your project pointing to the local NuGet feed directory.
4. Search for `OptimizelyToSitecore.Accelerator.Toolkit` in the NuGet Package Manager and install it.
   
   *Alternatively, add the reference directly to your `.csproj` file:*
   ```xml
   <PackageReference Include="OptimizelyToSitecore.Accelerator.Toolkit" Version="8.10.26" /> 
   ```
5. Build the solution. The export tools will now be available in the Optimizely CMS Admin UI under **Scheduled Jobs**.

### B. Installing the Sitecore Import Scripts
The Sitecore ingestion tools are packaged as a standard Sitecore installation ZIP, located in the `Installers/` directory of this repository.
- ⏬ **Download:** [Optimizely-To-Sitecore-Accelerator-Toolkit-1.0.zip](https://github.com/KalpeshTandel/OptimizelyToSitecore.Accelerator.Toolkit/tree/main/Installers)

**For Sitecore XP/XM (Pre-10.5):**
1. Log into your Sitecore Desktop (or Launchpad).
2. Navigate to **Development Tools > Installation Wizard**.
3. Upload and install the `Optimizely-To-Sitecore-Accelerator-Toolkit-1.0.zip` package.

**For Sitecore 10.5+ / XM Cloud (via SCS):**
Sitecore 10.5 onwards deprecates the traditional package installer. You can use the Sitecore Content Serialization (SCS) Item Package instead.
1. Locate `Optimizely-To-Sitecore-Accelerator-Toolkit-1.0.itempackage` in the `Installers/` directory of this repository.
- ⏬ **Download:** [Optimizely-To-Sitecore-Accelerator-Toolkit-1.0.itempackage](https://github.com/KalpeshTandel/OptimizelyToSitecore.Accelerator.Toolkit/tree/main/Installers)

2. Run the following CLI command in your Sitecore Serialization code-base:
   ```bash
   dotnet sitecore ser pkg install -f ".\Optimizely-To-Sitecore-Accelerator-Toolkit-1.0.itempackage" -n your-target-environment
   ```

*Once installed, the import tools are available in the **PowerShell Toolbox** (Start Menu > PowerShell Toolbox > Optimizely To Sitecore Accelerator Toolkit).*

---

## 2. Configuration Settings

If your implementation utilizes `appsettings.json` to manage C# settings, add the following `ExportSettings` block to your Optimizely project's configuration file to control the export destinations and boundaries.

```json
"ExportSettings": {
  "ExportDirectory": "App_Data/Export",
  "ContentExport": {
    "ContentRootId": "5",
    "IncludeSubItems": true,
    "IncludeMediaFiles": true,
    "TypesToExport": []
  },
  "MediaExport": {
    "MediaFolderRootId": 0,
    "IncludeSubFolders": true
  }
}
```

### Configuration Keys Explained:
*   `ExportDirectory`: The local physical path on the Optimizely server where jobs will securely save the JSON/ZIP files.
*   `ContentRootId`: The Optimizely Page/Folder ID (integer) where the content export should begin.
*   `IncludeSubItems`: When `true`, recursively traverses down the tree to export all descendants.
*   `IncludeMediaFiles`: When `true`, automatically extracts physical media blobs and generates a `map.json` inside the content ZIP.
*   `TypesToExport`: Optional array of specific Content Type names (e.g., `["ArticlePage"]`). Leave empty to export all types.
*   `MediaFolderRootId`: The Optimizely assets Folder ID where media export should begin (Leave as `0` for the Global Media Library).
*   `IncludeSubFolders`: When `true`, recursively traverses down the tree to export all descendants of MediaFolderRootId.
---

## 3. Execution: The 3-Phase Migration Workflow

Follow this sequence to execute a complete migration seamlessly.

### Phase 1: Schema Migration (Templates)
1. **Extract:** In the Optimizely CMS Admin UI, run the scheduled job: `Optimizely To Sitecore Accelerator: Export Templates`.
2. **Move:** Download the resulting `Optimizely-templates.json` file to your local machine.
3. **Generate:** Open the Sitecore PowerShell Toolbox, run **Import Templates**. Select your destination Template folder, click Next, and upload the JSON file.

### Phase 2: Media Migration
1. **Extract:** In the Optimizely Admin UI, run the job: `Optimizely To Sitecore Accelerator: Media Only Export`. 
2. **Move:** Download the resulting ZIP bundle.
3. **Generate:** Open the Sitecore PowerShell Toolbox, run **Import Media Files**. Select your target Media Library root and upload the ZIP. 
   *(This step unpacks the ZIP, creates items, uploads blobs, generates thumbnails, and preserves original Optimizely GUIDs).*

### Phase 3: Content Migration
1. **Extract:** In the Optimizely Admin UI, run the job: `Optimizely To Sitecore Accelerator: Export Content with Media Bundle to Sitecore`.
2. **Move:** Download the resulting ZIP bundle.
3. **Generate:** Open the Sitecore PowerShell Toolbox, run **Import Pages and Content**. Select your target Content and Media roots and upload the ZIP.
   *(This job reads the JSON, instantiates templates, routes Local Blocks into `/Data/` folders, and maps legacy Optimizely GUIDs to Sitecore Droptree/Droplink fields).*

---

### Contributing & Feedback
This tool was created to help the community accelerate replatforming efforts. If you encounter bugs, have feature requests, or want to contribute, please open an Issue or submit a Pull Request!