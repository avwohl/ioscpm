# Remote Help System

This document describes the remote help system used by iOSCPM and related clients (Windows, web).

## Overview

Help documentation is hosted in GitHub Releases and fetched on-demand by clients. This allows:
- Updating help content without app updates
- Reducing app bundle size
- Consistent documentation across all platforms

## Architecture

```
GitHub Release Assets:
├── help_index.json      # Index of all help topics
├── help_quick_start.md  # Individual help files
├── help_cpm22.md
├── help_zsdos.md
└── ...
```

Clients fetch from:
```
https://github.com/avwohl/ioscpm/releases/latest/download/
```

## help_index.json Format

```json
{
  "version": 1,
  "base_url": "https://github.com/avwohl/ioscpm/releases/latest/download/",
  "topics": [
    {
      "id": "quick_start",
      "title": "Quick Start Guide",
      "description": "Getting started with iOSCPM",
      "filename": "help_quick_start.md"
    }
  ]
}
```

### Fields

| Field | Description |
|-------|-------------|
| `version` | Index version number (increment when structure changes) |
| `base_url` | Base URL for fetching help files |
| `topics` | Array of available help topics |
| `topics[].id` | Unique identifier for the topic |
| `topics[].title` | Display title |
| `topics[].description` | Short description for topic list |
| `topics[].filename` | Filename to fetch (appended to base_url) |

## Client Implementation

### 1. Fetch Index

On help view open, fetch `help_index.json`:

```
GET https://github.com/avwohl/ioscpm/releases/latest/download/help_index.json
```

Cache the index locally with a TTL (e.g., 1 hour).

### 2. Display Topic List

Parse the index and display topics with title and description.

### 3. Fetch Topic On-Demand

When user selects a topic, fetch the markdown file:

```
GET {base_url}{filename}
```

For example:
```
GET https://github.com/avwohl/ioscpm/releases/latest/download/help_quick_start.md
```

### 4. Render Markdown

Render the fetched markdown content. Most platforms have markdown rendering libraries:
- **iOS/macOS**: Use `AttributedString` with markdown or a library like MarkdownUI
- **Windows**: Use a WebView with a markdown-to-HTML library
- **Web**: Use marked.js or similar

### 5. Caching Strategy

- Cache fetched help files locally
- Use ETag/Last-Modified headers for cache validation
- Fallback to cached content if offline

## Adding New Help Topics

1. Create the markdown file: `release_assets/help_newtopic.md`
2. Add entry to `release_assets/help_index.json`
3. Increment index version if structure changed
4. Create new GitHub release with updated assets

## Updating Existing Help

1. Edit the markdown file in `release_assets/`
2. Create new GitHub release
3. Clients will fetch updated content (based on cache policy)

## File Naming Convention

All help files use the prefix `help_` followed by a descriptive name:
- `help_quick_start.md`
- `help_cpm22.md`
- `help_file_transfer.md`

## Error Handling

Clients should:
- Show loading indicator while fetching
- Display error message if fetch fails
- Offer retry option
- Fall back to cached content if available

## Platform-Specific Implementation Examples

### Windows (C++/WinRT)

```cpp
// Fetch index
winrt::Windows::Web::Http::HttpClient client;
auto response = co_await client.GetStringAsync(
    winrt::Windows::Foundation::Uri(L"https://github.com/avwohl/ioscpm/releases/latest/download/help_index.json"));

// Parse JSON
auto json = winrt::Windows::Data::Json::JsonObject::Parse(response);
auto topics = json.GetNamedArray(L"topics");

// Display in ListView, fetch content on selection
// Render markdown in WebView2 using a JS library like marked.js
```

### Web (JavaScript)

```javascript
// Fetch and display help
async function loadHelp() {
    const indexUrl = 'https://github.com/avwohl/ioscpm/releases/latest/download/help_index.json';
    const response = await fetch(indexUrl);
    const index = await response.json();

    // Build topic list
    const list = document.getElementById('help-topics');
    index.topics.forEach(topic => {
        const item = document.createElement('div');
        item.innerHTML = `<h3>${topic.title}</h3><p>${topic.description}</p>`;
        item.onclick = () => loadTopic(index.base_url + topic.filename);
        list.appendChild(item);
    });
}

async function loadTopic(url) {
    const response = await fetch(url);
    const markdown = await response.text();
    document.getElementById('help-content').innerHTML = marked.parse(markdown);
}
```

## Current Help Topics

| ID | Title | Filename |
|----|-------|----------|
| quick_start | Quick Start Guide | help_quick_start.md |
| cpm22 | CP/M 2.2 User Guide | help_cpm22.md |
| zsdos | ZSDOS User Guide | help_zsdos.md |
| nzcom | NZCOM User Guide | help_nzcom.md |
| zpm3 | ZPM3 User Guide | help_zpm3.md |
| qpm | QP/M User Guide | help_qpm.md |
| file_transfer | File Transfer (R8/W8) | help_file_transfer.md |
