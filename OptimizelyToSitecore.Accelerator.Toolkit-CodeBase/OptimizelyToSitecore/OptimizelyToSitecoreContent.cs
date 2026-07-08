using EPiServer;
using EPiServer.Cms.Shell;
using EPiServer.Core;
using EPiServer.DataAbstraction;
using EPiServer.PlugIn;
using EPiServer.Scheduler;
using Microsoft.AspNetCore.Hosting;
using Microsoft.Extensions.Configuration;
using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace OptimizelyToSitecore.Accelerator.Toolkit
{
    // --- JSON Manifest Models ---
    public class OptiExportContentItem
    {
        public string ItemId { get; set; }
        public string Name { get; set; }
        public string Path { get; set; }
        public string TemplateId { get; set; }
        public string Language { get; set; }
        public Dictionary<string, string> Fields { get; set; }
    }

    public class OptiExportMediaItem
    {
        public string ItemId { get; set; }
        public string Name { get; set; }
        public string AltText { get; set; }
        public string Path { get; set; }
        public string FileName { get; set; }
    }

    [ScheduledPlugIn(
        DisplayName = "Optimizely To Sitecore Accelerator: Export Content with Media Bundle to Sitecore",
        Description = "Traverses Optimizely content, extracts media, translates links, and builds a Sitecore-ready ZIP bundle.")]
    public class OptimizelyContentExportJob : ScheduledJobBase
    {
        private readonly IContentRepository _contentRepository;
        private readonly ILanguageBranchRepository _languageBranchRepository;
        private readonly IContentTypeRepository _contentTypeRepository;
        private readonly IWebHostEnvironment _env;
        private readonly IConfiguration _config;

        // Queues and Tracking to ensure we get all dependencies but avoid infinite loops
        private HashSet<Guid> _processedItems = new HashSet<Guid>();
        private Queue<ContentReference> _contentQueue = new Queue<ContentReference>();

        private List<OptiExportContentItem> _exportedContent = new List<OptiExportContentItem>();
        private List<OptiExportMediaItem> _exportedMedia = new List<OptiExportMediaItem>();

        // Toggles
        private bool _includeSubItems;
        private bool _includeMediaFiles;

        public OptimizelyContentExportJob(
            IContentRepository contentRepository,
            ILanguageBranchRepository languageBranchRepository,
            IContentTypeRepository contentTypeRepository,
            IWebHostEnvironment env,
            IConfiguration config)
        {
            _contentRepository = contentRepository;
            _languageBranchRepository = languageBranchRepository;
            _contentTypeRepository = contentTypeRepository;
            _env = env;
            _config = config;
            IsStoppable = false;
        }

        public override string Execute()
        {
            _processedItems.Clear();
            _contentQueue.Clear();
            _exportedContent.Clear();
            _exportedMedia.Clear();

            // Read settings from appsettings.json
            string exportRootIdStr = _config["ExportSettings:ContentExport:ContentRootId"];
            if (string.IsNullOrEmpty(exportRootIdStr) || !int.TryParse(exportRootIdStr, out int exportRootId))
            {
                return "Error: Missing or invalid ExportSettings:ExportRootId in appsettings.json";
            }

            _includeSubItems = _config.GetValue<bool>("ExportSettings:ContentExport:IncludeSubItems", true);
            _includeMediaFiles = _config.GetValue<bool>("ExportSettings:ContentExport:IncludeMediaFiles", true);

            // 1. Setup Export Directories
            string timestamp = DateTime.Now.ToString("yyyyMMddHHmmss");
            string tempDir = Path.Combine(Path.GetTempPath(), $"OptiExport_{timestamp}");
            string assetsDir = Path.Combine(tempDir, "assets");

            if (_includeMediaFiles)
            {
                Directory.CreateDirectory(assetsDir);
            }
            else
            {
                Directory.CreateDirectory(tempDir);
            }

            try
            {
                // 2. Traverse the Tree (Start at Root)
                var rootPage = new ContentReference(exportRootId);
                TraverseTree(rootPage);

                // 3. Process the Queue
                ProcessQueue(assetsDir);

                // 4. Generate JSON Manifests
                string contentJsonPath = Path.Combine(tempDir, "Optimizely-content.json");
                string mapJsonPath = Path.Combine(tempDir, "map.json");

                File.WriteAllText(contentJsonPath, JsonSerializer.Serialize(_exportedContent, new JsonSerializerOptions { WriteIndented = true }));

                if (_includeMediaFiles && _exportedMedia.Count > 0)
                {
                    File.WriteAllText(mapJsonPath, JsonSerializer.Serialize(_exportedMedia, new JsonSerializerOptions { WriteIndented = true }));
                }

                // 5. Zip it up
                string outputDirSetting = _config["ExportSettings:ExportDirectory"] ?? "App_Data/Export";
                string outputDir = Path.Combine(_env.ContentRootPath, outputDirSetting);
                Directory.CreateDirectory(outputDir);

                string zipPath = Path.Combine(outputDir, $"OptimizelyMigrationBundle_{timestamp}.zip");
                ZipFile.CreateFromDirectory(tempDir, zipPath);

                string status = $"Export Complete! {zipPath}. Exported {_exportedContent.Count} content items.";
                if (_includeMediaFiles) status += $" and {_exportedMedia.Count} media items.";

                return status;
            }
            finally
            {
                if (Directory.Exists(tempDir)) Directory.Delete(tempDir, true);
            }
        }

        private void TraverseTree(ContentReference currentRef)
        {
            _contentQueue.Enqueue(currentRef);

            // Only recurse down the tree if IncludeSubItems is true
            if (_includeSubItems)
            {
                var children = _contentRepository.GetChildren<IContent>(currentRef);
                foreach (var child in children)
                {
                    if (child is PageData || child is ContentFolder)
                    {
                        TraverseTree(child.ContentLink);
                    }
                }
            }
        }

        private void ProcessQueue(string assetsDir)
        {
            // NEW: Fetch specific types to export if filtering is enabled
            var specificTypesToExport = _config.GetSection("ExportSettings:ContentExport:TypesToExport").Get<List<string>>() ?? new List<string>();
            bool hasFilter = specificTypesToExport.Any();

            while (_contentQueue.Count > 0)
            {
                var contentRef = _contentQueue.Dequeue();

                if (!_contentRepository.TryGet<IContent>(contentRef, out var content)) continue;

                Guid contentGuid = content.ContentGuid;
                if (_processedItems.Contains(contentGuid)) continue;
                _processedItems.Add(contentGuid);

                // IF MEDIA
                if (content is MediaData mediaData)
                {
                    if (_includeMediaFiles)
                    {
                        ExportMedia(mediaData, assetsDir);
                    }
                    continue;
                }

                // IF FOLDER
                if (content is ContentFolder) continue;

                // FILTERING CHECK
                if (hasFilter && !specificTypesToExport.Contains(content.GetOriginalType().Name, StringComparer.OrdinalIgnoreCase))
                {
                    continue; // Skip exporting this page/block if it isn't in the filter array
                }

                // IF PAGE or BLOCK
                var branches = _contentRepository.GetLanguageBranches<IContent>(contentRef);
                foreach (var branch in branches)
                {
                    ExportContentBranch(branch);
                }
            }
        }

        private void ExportMedia(MediaData media, string assetsDir)
        {
            string ext = Path.GetExtension(media.RouteSegment);
            if (string.IsNullOrEmpty(ext)) ext = ".jpg";

            string safeFileName = $"{media.ContentGuid}{ext}";
            string physicalPath = Path.Combine(assetsDir, safeFileName);

            using (var fs = File.Create(physicalPath))
            using (var blobStream = media.BinaryData.OpenRead())
            {
                blobStream.CopyTo(fs);
            }

            string altText = media.Property.Contains("AltText") ? media.Property["AltText"].Value?.ToString() : "";

            _exportedMedia.Add(new OptiExportMediaItem
            {
                ItemId = media.ContentGuid.ToString(),
                Name = media.Name,
                AltText = altText,
                Path = GetPath(media.ContentLink),
                FileName = safeFileName
            });
        }

        private void ExportContentBranch(IContent contentBranch)
        {
            if((contentBranch as ILocalizable)?.Language?.Name == "sv")
            {
                return;
            }
            Guid templateId = GetContentTypeGuid(contentBranch);
            var exportItem = new OptiExportContentItem
            {
                ItemId = contentBranch.ContentGuid.ToString(),
                Name = contentBranch.Name,
                TemplateId = templateId.ToString(),
                Language = (contentBranch as ILocalizable)?.Language?.Name ?? "en",
                Path = GetPath(contentBranch.ContentLink),
                Fields = new Dictionary<string, string>()
            };

            foreach (var property in contentBranch.Property)
            {
                if (property.Name.StartsWith("Page") && property.Name != "PageName") continue;
                if (property.Value == null) continue;

                string stringValue = ExtractPropertyValue(property);
                if (!string.IsNullOrEmpty(stringValue))
                {
                    exportItem.Fields[property.Name] = stringValue;
                }
            }

            _exportedContent.Add(exportItem);
        }

        private string ExtractPropertyValue(PropertyData property)
        {
            try
            {
                // 1. Content Reference (Link to Page/Block/Media)
                if (property.Type == PropertyDataType.PageReference || property.Type == PropertyDataType.ContentReference)
                {
                    ContentReference cRef = (ContentReference)property.Value;
                    if (ContentReference.IsNullOrEmpty(cRef)) return null;
                    if (_contentRepository.TryGet<IContent>(cRef, out var linkedItem))
                    {
                        // Enqueue if it's not media, OR if it is media and media is enabled
                        bool isMedia = linkedItem is MediaData;
                        if (!isMedia || (isMedia && _includeMediaFiles))
                        {
                            if (!_processedItems.Contains(linkedItem.ContentGuid))
                                _contentQueue.Enqueue(cRef);
                        }

                        return linkedItem.ContentGuid.ToString();
                    }
                }

                // 2. Content Area (List of Blocks/Pages)
                if (property.Value is ContentArea contentArea && contentArea.Items != null)
                {
                    var guidList = new List<string>();
                    foreach (var item in contentArea.Items)
                    {
                        if (_contentRepository.TryGet<IContent>(item.ContentLink, out var linkedItem))
                        {
                            bool isMedia = linkedItem is MediaData;
                            if (!isMedia || (isMedia && _includeMediaFiles))
                            {
                                if (!_processedItems.Contains(linkedItem.ContentGuid))
                                    _contentQueue.Enqueue(item.ContentLink);
                            }

                            guidList.Add(linkedItem.ContentGuid.ToString());
                        }
                    }
                    return JsonSerializer.Serialize(guidList);
                }

                // 3. Rich Text (XhtmlString)
                if (property.Value is XhtmlString xhtmlString)
                {
                    string html = xhtmlString.ToHtmlString();

                    html = Regex.Replace(html, @"(?:href|src)=[""'](?:~/|/)?link/([0-9a-fA-F]{32})(?:\.aspx)?[""']", match =>
                    {
                        Guid extractedGuid = Guid.Parse(match.Groups[1].Value);
                        return $"href=\"~/link/{{{extractedGuid.ToString().ToUpper()}}}.aspx\"";
                    });

                    return html;
                }

                // 4. Primitive Fallback
                return property.Value.ToString();
            }
            catch
            {
                return null;
            }
        }

        private string GetPath(ContentReference contentLink)
        {
            var pathList = new List<string>();
            var current = contentLink;

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

        public Guid GetContentTypeGuid(IContent content)
        {
            // Get the structural content type definition from the repository
            var contentType = _contentTypeRepository.Load(content.ContentTypeID);

            // Return its unique GUID
            return contentType.GUID;
        }
    }
}