using EPiServer;
using EPiServer.Core;
using EPiServer.PlugIn;
using EPiServer.Scheduler;
using EPiServer.Web;
using Microsoft.AspNetCore.Hosting;
using Microsoft.Extensions.Configuration;
using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Text.Json;

namespace OptimizelyToSitecore.Accelerator.Toolkit
{

    [ScheduledPlugIn(
        DisplayName = "Optimizely To Sitecore Accelerator: Media Only Export",
        Description = "Exports only a specific media folder (and subfolders) into a ZIP bundle for Sitecore."
    )]
    public class OptimizelyMediaOnlyExportJob : ScheduledJobBase
    {
        private readonly IContentRepository _contentRepository;
        private readonly IWebHostEnvironment _webHostEnvironment;
        private readonly IConfiguration _config;
        private readonly IWebHostEnvironment _env;

        private bool includeSubFolders;
        public OptimizelyMediaOnlyExportJob(IContentRepository contentRepository, IWebHostEnvironment webHostEnvironment, IConfiguration config, IWebHostEnvironment env)
        {
            _contentRepository = contentRepository;
            _webHostEnvironment = webHostEnvironment;
            _config = config;
            _env = env;
        }

        public override string Execute()
        {
            // Set to a specific Optimizely Folder ID (e.g., 145). 
            // Leave as 0 to export the entire Global Media Library.
            // Read settings from appsettings.json
            string targetMediaRootIdStr = _config["ExportSettings:MediaExport:MediaFolderRootId"];
            if (string.IsNullOrEmpty(targetMediaRootIdStr) || !int.TryParse(targetMediaRootIdStr, out int targetMediaRootId))
            {
                targetMediaRootId = 0;
            }

            includeSubFolders = _config.GetValue<bool>("ExportSettings:MediaExport:IncludeSubFolders", true);

            // 1. Setup Export Directories
            string timestamp = DateTime.Now.ToString("yyyyMMddHHmmss");
            string tempDir = Path.Combine(Path.GetTempPath(), $"OptiMediaExport_{timestamp}");
            string assetsDir = Path.Combine(tempDir, "assets");
            Directory.CreateDirectory(assetsDir);

            int mediaCount = 0;

            try
            {
                ContentReference startRoot = targetMediaRootId > 0
                    ? new ContentReference(targetMediaRootId)
                    : SiteDefinition.Current.GlobalAssetsRoot;

                // 1. Fetch Media References based on SubFolder configuration
                IEnumerable<ContentReference> mediaRefs;
                if (includeSubFolders)
                {
                    mediaRefs = _contentRepository.GetDescendents(startRoot);
                }
                else
                {
                    mediaRefs = _contentRepository.GetChildren<IContent>(startRoot).Select(c => c.ContentLink);
                }

                // 2. Resolve to MediaData
                var allMedia = mediaRefs
                    .Select(r => _contentRepository.Get<IContent>(r))
                    .OfType<MediaData>()
                    .ToList();

                var mediaJsonList = new List<OptiExportMediaItem>();

                // 3. Process each Media item
                foreach (var media in allMedia)
                {
                    string ext = Path.GetExtension(media.RouteSegment);
                    if (string.IsNullOrEmpty(ext)) ext = ".jpg";

                    string safeFileName = $"{media.ContentGuid}{ext}";
                    string physicalPath = Path.Combine(assetsDir, safeFileName);

                    // Read Blob and save to temp folder
                    using (var blobStream = media.BinaryData.OpenRead())
                    using (var fileStream = new FileStream(physicalPath, FileMode.Create, FileAccess.Write))
                    {
                        blobStream.CopyTo(fileStream);
                    }

                    // Extract Alt Text if it exists
                    string altText = "";
                    if (media.Property.Contains("AltText") && media.Property["AltText"].Value != null)
                    {
                        altText = media.Property["AltText"].Value.ToString();
                    }

                    mediaJsonList.Add(new OptiExportMediaItem
                    {
                        ItemId = media.ContentGuid.ToString(),
                        Name = media.Name,
                        AltText = altText,
                        Path = GetPath(media.ContentLink),
                        FileName = safeFileName
                    });

                    mediaCount++;
                }

                // 4. Save JSON Manifest
                string jsonPath = Path.Combine(tempDir, "map.json");
                File.WriteAllText(jsonPath, JsonSerializer.Serialize(mediaJsonList, new JsonSerializerOptions { WriteIndented = true }));

                // 5. Zip the bundle
                string outputDirSetting = _config["ExportSettings:ExportDirectory"] ?? "App_Data/Export";
                string outputDir = Path.Combine(_env.ContentRootPath, outputDirSetting);
                Directory.CreateDirectory(outputDir);

                string zipPath = Path.Combine(outputDir, $"OptimizelyMediaOnlyBundle_{timestamp}.zip");
                if (File.Exists(zipPath)) File.Delete(zipPath);
                ZipFile.CreateFromDirectory(tempDir, zipPath);

                return $"Media export complete! Exported {mediaCount} media items. Download at: {zipPath}";
            }
            catch (Exception ex)
            {
                return $"Error during media export: {ex.Message}";
            }
            finally
            {
                if (Directory.Exists(tempDir))
                {
                    Directory.Delete(tempDir, true);
                }
            }
        }

        private string GetPath(ContentReference contentLink)
        {
            var pathList = new List<string>();
            var current = contentLink;

            // Go up the tree to build the path structure
            while (!ContentReference.IsNullOrEmpty(current) && current.ID != ContentReference.RootPage.ID)
            {
                if (_contentRepository.TryGet<IContent>(current, out var content))
                {
                    pathList.Add(content.Name);
                    current = content.ParentLink;
                }
                else break;
            }

            pathList.Reverse();
            return "/" + string.Join("/", pathList);
        }
    }
}