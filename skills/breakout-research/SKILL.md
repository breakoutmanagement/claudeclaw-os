---
name: breakout-research
description: Search and retrieve video research, transcripts, summaries, and actionable insights from the Breakout Research platform (1300+ analyzed YouTube videos)
triggers:
  - research
  - breakout
  - video research
  - youtube research
  - transcript
  - video summary
  - video insights
  - what does X say about
  - find videos about
allowed-tools: Bash(curl -fsS *api.research.breakoutwithai.com*)
---

# Breakout Research Platform

Internal research platform with 1300+ YouTube videos fully analyzed: transcripts, structured summaries (problem/solution/tradeoffs/decision framework), and actionable insights.

## Authentication

API key is in `.env` as `BREAKOUT_API_KEY`. Always load it:

```bash
export BREAKOUT_API_KEY=$(grep BREAKOUT_API_KEY "$(git rev-parse --show-toplevel)/.env" | cut -d= -f2-)
```

Every request needs:
```
-H "Authorization: Bearer $BREAKOUT_API_KEY"
```

## Base URL

```
https://api.research.breakoutwithai.com
```

## Endpoints

### Health check (no auth)
```bash
curl -fsS https://api.research.breakoutwithai.com/api/health
```

### List videos
```bash
curl -fsS -H "Authorization: Bearer $BREAKOUT_API_KEY" \
  "https://api.research.breakoutwithai.com/api/v1/videos?limit=20"
```

Returns `{ success, data: { videos: [...], total, limit } }`.

Each video object contains: `videoId`, `title`, `description`, `channelName`, `uploadDate`, `transcriptStatus`, `summaryStatus`, `wordCount`, `transcriptSummary`, `actionableInsights`, `tags`.

Only videos with `transcriptStatus: "completed"` and `summaryStatus: "completed"` have full data.

### Get single video (metadata + summary, no transcript)
```bash
curl -fsS -H "Authorization: Bearer $BREAKOUT_API_KEY" \
  "https://api.research.breakoutwithai.com/api/v1/videos/VIDEO_ID"
```

Returns the video object including:
- `title`, `description` - video metadata
- `channelName`, `channelId` - creator info
- `uploadDate`, `durationSeconds`, `viewCount`, `likeCount`
- `transcriptSummary` - structured markdown summary with sections: Problem, Key Mechanisms/Solutions, Tradeoffs & Gaps, Decision Framework, TL;DR
- `actionableInsights` - numbered list of concrete takeaways
- `wordCount` - transcript length
- `tags` - topic tags

NOTE: This does NOT include the raw transcript. To get it, add `?include_transcript=true`.

### Get single video WITH raw transcript
```bash
curl -fsS -H "Authorization: Bearer $BREAKOUT_API_KEY" \
  "https://api.research.breakoutwithai.com/api/v1/videos/VIDEO_ID?include_transcript=true"
```

Same as above, plus `data.transcriptText` containing the full raw transcript text. Only use this when you actually need the transcript, payloads can be large (50K+ chars).

### Submit a video for research (preferred for URL-based lookups)
```bash
curl -fsS -X POST \
  -H "Authorization: Bearer $BREAKOUT_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"url":"https://www.youtube.com/watch?v=VIDEO_ID"}' \
  "https://api.research.breakoutwithai.com/api/v1/research"
```

For already-ingested videos, this is a cache hit and returns the full object including `data.transcript.text` (raw text) and `data.transcript.segments[]` (timestamped segments with start/end times). This is the richest response format.

Returns 202 if queued (new video). NOTE: Cold submissions for videos not already in the system may return 500 (known issue #227). Stick to already-ingested videos for now.

## Response codes
- 200 - success
- 202 - queued (poll the video endpoint for status)
- 401 - missing token
- 403 - wrong token
- 500 - server error (for cold submissions, see #227)

## How to use this skill

### When the user asks to research a topic:
1. List videos to browse what's available, or search by scanning titles
2. Fetch specific videos that look relevant
3. Synthesize the `transcriptSummary` and `actionableInsights` across multiple videos into a coherent answer
4. Always cite which video(s) you pulled from (title + channelName)

### When the user shares a YouTube URL or video ID:
1. Extract the video ID from the URL
2. Fetch it directly with the get-by-id endpoint
3. If it's not in the system, tell the user (don't submit cold URLs for now)

### When summarizing research:
- Lead with the answer, then cite sources
- Pull from `transcriptSummary` for depth and `actionableInsights` for practical takeaways
- If multiple videos cover the same topic, synthesize across them rather than listing each one separately

## Searching across videos

The API doesn't have a search endpoint yet. To find videos on a topic:
1. Fetch a batch with `?limit=50`
2. Scan titles for relevance
3. Fetch the promising ones individually for full summaries
4. Repeat with offset if needed: `?limit=50&offset=50`

This is a bit manual but works. The dataset is ~1300 videos so a few batches usually covers it.
