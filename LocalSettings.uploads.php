<?php
# =============================================================================
# Upload settings
# Mounted into the wikibase container as a LocalSettings.d drop-in.
# =============================================================================

# Enable uploads (base image sets this to false; override here).
$wgEnableUploads = true;

# Allow users and sysops to upload files.
$wgGroupPermissions['user']['upload'] = true;
$wgGroupPermissions['sysop']['upload'] = true;
$wgGroupPermissions['sysop']['reupload'] = true;
$wgGroupPermissions['sysop']['reupload-shared'] = true;

# Accepted file extensions.
$wgFileExtensions = [
    // Images
    'png', 'gif', 'jpg', 'jpeg', 'webp', 'svg',
    // Documents
    'pdf',
    // Data
    'csv', 'json', 'xml',
    // Archives
    'zip',
    // Office
    'odt', 'ods', 'odp', 'docx', 'xlsx', 'pptx',
];

# Warn (but do not block) if the upload exceeds this size (bytes).
# Keep in sync with upload_max_filesize in php/uploads.ini.
$wgUploadSizeWarning = 125829120; // 120 MiB
