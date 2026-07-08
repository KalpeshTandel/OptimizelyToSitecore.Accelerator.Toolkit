using EPiServer.Core;
using EPiServer.DataAbstraction;
using EPiServer.PlugIn;
using EPiServer.Scheduler;
using Microsoft.AspNetCore.Hosting;
using Microsoft.Extensions.Configuration;
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace OptimizelyToSitecore.Accelerator.Toolkit
{
    // --- JSON Manifest Models for Templates ---
    public class SitecoreTemplateManifest
    {
        public string TemplateId { get; set; }
        public string Name { get; set; }
        public string DisplayName { get; set; }
        public string BaseType { get; set; } // Page or Block
        public List<SitecoreFieldManifest> Fields { get; set; }
    }

    public class SitecoreFieldManifest
    {
        public string FieldId { get; set; }
        public string Name { get; set; }
        public string DisplayName { get; set; } // Captures editor-friendly name
        public bool IsShared { get; set; }      // Captures language routing
        public string SitecoreFieldType { get; set; }
        public string OriginalOptimizelyType { get; set; }
        public string SectionName { get; set; }
        public string SortOrder { get; set; }
    }

    [ScheduledPlugIn(
        DisplayName = "Optimizely To Sitecore Accelerator: Export Templates",
        Description = "Extracts Optimizely Page/Block types and maps them to a Sitecore Template JSON manifest.")]
    public class OptimizelyTemplateExportJob : ScheduledJobBase
    {
        private readonly IContentTypeRepository _contentTypeRepository;
        private readonly IWebHostEnvironment _env;
        private readonly IConfiguration _config;

        public OptimizelyTemplateExportJob(
            IContentTypeRepository contentTypeRepository,
            IWebHostEnvironment env,
            IConfiguration config)
        {
            _contentTypeRepository = contentTypeRepository;
            _env = env;
            _config = config;
            IsStoppable = false;
        }

        public override string Execute()
        {
            var exportedTemplates = new List<SitecoreTemplateManifest>();

            // 1. Get all Content Types (Pages, Blocks, Media)
            var contentTypes = _contentTypeRepository.List();

            foreach (var contentType in contentTypes)
            {
                // We typically only want to export Pages and Blocks as Sitecore Templates
                bool isPage = contentType.Base == ContentTypeBase.Page;
                bool isBlock = contentType.Base == ContentTypeBase.Block;

                if (!isPage && !isBlock) continue;

                var templateManifest = new SitecoreTemplateManifest
                {
                    TemplateId = contentType.GUID.ToString(),
                    Name = contentType.Name,
                    DisplayName = contentType.DisplayName ?? contentType.Name,
                    BaseType = isPage ? "Page" : "Block",
                    Fields = new List<SitecoreFieldManifest>()
                };

                // 2. Iterate through Properties and Map to Sitecore Types
                foreach (var prop in contentType.PropertyDefinitions)
                {
                    // Skip Optimizely built-in system fields
                    if (prop.Name.StartsWith("Page") || prop.Name.StartsWith("Block") || prop.Name.StartsWith("ictrl"))
                        continue;

                    templateManifest.Fields.Add(new SitecoreFieldManifest
                    {
                        // Generate a deterministic GUID using the Template GUID + Field Name
                        FieldId = GenerateDeterministicGuid($"{contentType.GUID}_{prop.Name}").ToString(),
                        Name = prop.Name,

                        // Map the Display Name (EditCaption in Optimizely)
                        DisplayName = !string.IsNullOrWhiteSpace(prop.EditCaption) ? prop.EditCaption : prop.Name,

                        // Invert Optimizely's "LanguageSpecific" to match Sitecore's "IsShared"
                        IsShared = !prop.LanguageSpecific,

                        OriginalOptimizelyType = prop.Type.DataType.ToString(),
                        SectionName = prop.Tab.LocalizedName,
                        SortOrder = prop.FieldOrder.ToString(),
                        SitecoreFieldType = MapToSitecoreFieldType(prop.Type.DataType, prop.Type.Name,prop.TemplateHint)
                    });
                }

                exportedTemplates.Add(templateManifest);
            }

            // 3. Save to JSON File
            string outputDirSetting = _config["ExportSettings:ExportDirectory"] ?? "App_Data/Export";
            string outputDir = Path.Combine(_env.ContentRootPath, outputDirSetting);
            Directory.CreateDirectory(outputDir);

            string jsonPath = Path.Combine(outputDir, "Optimizely-templates.json");
            File.WriteAllText(jsonPath, JsonSerializer.Serialize(exportedTemplates, new JsonSerializerOptions { WriteIndented = true }));

            return $"Success! Exported {exportedTemplates.Count} templates to {jsonPath}";
        }

        // --- Deterministic GUID Generator ---
        private Guid GenerateDeterministicGuid(string input)
        {
            using (MD5 md5 = MD5.Create())
            {
                byte[] hash = md5.ComputeHash(Encoding.UTF8.GetBytes(input));
                return new Guid(hash);
            }
        }

        // --- Core Translation Engine ---
        private string MapToSitecoreFieldType(PropertyDataType dataType, string specificTypeName, string templateHint)
        {
            if (string.Equals(templateHint, "Image", StringComparison.OrdinalIgnoreCase) ||
            string.Equals(templateHint, "MediaFile", StringComparison.OrdinalIgnoreCase))
            {
                return "Image";
            }
            // Catch Optimizely's complex types using their string names 
            // since they don't have explicit PropertyDataType enum values.
            if (specificTypeName.Contains("ContentArea")) return "Treelist";
            if (specificTypeName.Contains("ContentReference")) return "Droptree";

            // Translates Optimizely C# data types to Sitecore's native field types
            switch (dataType)
            {
                case PropertyDataType.String:
                    if (specificTypeName.Contains("Url")) return "General Link";
                    if (specificTypeName.Contains("XhtmlString")) return "Rich Text";
                    return "Single-Line Text";

                case PropertyDataType.LongString:
                    if (specificTypeName.Contains("XhtmlString")) return "Rich Text";
                    return "Multi-Line Text";

                case PropertyDataType.Boolean:
                    return "Checkbox";

                case PropertyDataType.Number:
                case PropertyDataType.FloatNumber:
                    return "Number";

                case PropertyDataType.Date:
                    return "Datetime";

                case PropertyDataType.PageReference:
                case PropertyDataType.ContentReference: // Explicitly handle ContentReferences
                    return "Droptree"; // Single link selector

                case PropertyDataType.Block: // Optimizely uses Block for local blocks
                case PropertyDataType.LinkCollection:
                    return "Treelist"; // Multiple link selector

                default:
                    return "Single-Line Text";
            }
        }
    }
}